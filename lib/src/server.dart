// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:stack_trace/stack_trace.dart';
import 'package:stream_channel/stream_channel.dart';

import '../error_code.dart' as error_code;
import 'channel_manager.dart';
import 'exception.dart';
import 'parameters.dart';
import 'utils.dart';

/// A JSON-RPC 2.0 server.
///
/// A server exposes methods that are called by requests, to which it provides
/// responses. Methods can be registered using [registerMethod] and
/// [registerFallback]. Requests can be handled using [handleRequest] and
/// [parseRequest].
///
/// Note that since requests can arrive asynchronously and methods can run
/// asynchronously, it's possible for multiple methods to be invoked at the same
/// time, or even for a single method to be invoked multiple times at once.
class Server {
  final ChannelManager _manager;

  /// The methods registered for this server.
  final _methods = new Map<String, Function>();

  /// The fallback methods for this server.
  ///
  /// These are tried in order until one of them doesn't throw a
  /// [RpcException.methodNotFound] exception.
  final _fallbacks = new Queue<Function>();

  /// Returns a [Future] that completes when the underlying connection is
  /// closed.
  ///
  /// This is the same future that's returned by [listen] and [close]. It may
  /// complete before [close] is called if the remote endpoint closes the
  /// connection.
  Future get done => _manager.done;

  /// Whether the underlying connection is closed.
  ///
  /// Note that this will be `true` before [close] is called if the remote
  /// endpoint closes the connection.
  bool get isClosed => _manager.isClosed;

  /// Creates a [Server] that communicates over [channel].
  ///
  /// Note that the server won't begin listening to [requests] until
  /// [Server.listen] is called.
  Server(StreamChannel<String> channel)
      : this.withoutJson(
            jsonDocument.bind(channel).transform(respondToFormatExceptions));

  /// Creates a [Server] that communicates using decoded messages over
  /// [channel].
  ///
  /// Unlike [new Server], this doesn't read or write JSON strings. Instead, it
  /// reads and writes decoded maps or lists.
  ///
  /// Note that the server won't begin listening to [requests] until
  /// [Server.listen] is called.
  Server.withoutJson(StreamChannel channel)
      : _manager = new ChannelManager("Server", channel);

  /// Starts listening to the underlying stream.
  ///
  /// Returns a [Future] that will complete when the connection is closed or
  /// when it has an error. This is the same as [done].
  ///
  /// [listen] may only be called once.
  Future listen() => _manager.listen(_handleRequest);

  /// Closes the underlying connection.
  ///
  /// Returns a [Future] that completes when all resources have been released.
  /// This is the same as [done].
  Future close() => _manager.close();

  /// Registers a method named [name] on this server.
  ///
  /// [callback] can take either zero or one arguments. If it takes zero, any
  /// requests for that method that include parameters will be rejected. If it
  /// takes one, it will be passed a [Parameters] object.
  ///
  /// [callback] can return either a JSON-serializable object or a Future that
  /// completes to a JSON-serializable object. Any errors in [callback] will be
  /// reported to the client as JSON-RPC 2.0 errors.
  void registerMethod(String name, Function callback) {
    if (_methods.containsKey(name)) {
      throw new ArgumentError('There\'s already a method named "$name".');
    }

    _methods[name] = callback;
  }

  /// Registers a fallback method on this server.
  ///
  /// A server may have any number of fallback methods. When a request comes in
  /// that doesn't match any named methods, each fallback is tried in order. A
  /// fallback can pass on handling a request by throwing a
  /// [RpcException.methodNotFound] exception.
  ///
  /// [callback] can return either a JSON-serializable object or a Future that
  /// completes to a JSON-serializable object. Any errors in [callback] will be
  /// reported to the client as JSON-RPC 2.0 errors. [callback] may send custom
  /// errors by throwing an [RpcException].
  void registerFallback(callback(Parameters parameters)) {
    _fallbacks.add(callback);
  }

  /// Handle a request.
  ///
  /// [request] is expected to be a JSON-serializable object representing a
  /// request sent by a client. This calls the appropriate method or methods for
  /// handling that request and returns a JSON-serializable response, or `null`
  /// if no response should be sent. [callback] may send custom
  /// errors by throwing an [RpcException].
  Future _handleRequest(request) async {
    var response;
    if (request is List) {
      if (request.isEmpty) {
        response = new RpcException(error_code.INVALID_REQUEST,
                'A batch must contain at least one request.')
            .serialize(request);
      } else {
        var results = await Future.wait(request.map(_handleSingleRequest));
        var nonNull = results.where((result) => result != null);
        if (nonNull.isEmpty) return;
        response = nonNull.toList();
      }
    } else {
      response = await _handleSingleRequest(request);
      if (response == null) return;
    }

    if (!isClosed) _manager.add(response);
  }

  /// Handles an individual parsed request.
  Future _handleSingleRequest(request) async {
    try {
      _validateRequest(request);

      var name = request['method'];
      var method = _methods[name];
      if (method == null) method = _tryFallbacks;

      Object result;
      if (method is ZeroArgumentFunction) {
        if (request.containsKey('params')) {
          throw new RpcException.invalidParams('No parameters are allowed for '
              'method "$name".');
        }
        result = await method();
      } else {
        result = await method(new Parameters(name, request['params']));
      }

      // A request without an id is a notification, which should not be sent a
      // response, even if one is generated on the server.
      if (!request.containsKey('id')) return null;

      return {
        'jsonrpc': '2.0',
        'result': result,
        'id': request['id']
      };
    } catch (error, stackTrace) {
      if (error is RpcException) {
        if (error.code == error_code.INVALID_REQUEST ||
            request.containsKey('id')) {
          return error.serialize(request);
        } else {
          return null;
        }
      } else if (!request.containsKey('id')) {
        return null;
      }
      final chain = new Chain.forTrace(stackTrace);
      return new RpcException(error_code.SERVER_ERROR, getErrorMessage(error),
          data: {
            'full': '$error',
            'stack': '$chain',
          }).serialize(request);
    }
  }

  /// Validates that [request] matches the JSON-RPC spec.
  void _validateRequest(request) {
    if (request is! Map) {
      throw new RpcException(error_code.INVALID_REQUEST, 'Request must be '
          'an Array or an Object.');
    }

    if (!request.containsKey('jsonrpc')) {
      throw new RpcException(error_code.INVALID_REQUEST, 'Request must '
          'contain a "jsonrpc" key.');
    }

    if (request['jsonrpc'] != '2.0') {
      throw new RpcException(error_code.INVALID_REQUEST, 'Invalid JSON-RPC '
          'version ${JSON.encode(request['jsonrpc'])}, expected "2.0".');
    }

    if (!request.containsKey('method')) {
      throw new RpcException(error_code.INVALID_REQUEST, 'Request must '
          'contain a "method" key.');
    }

    var method = request['method'];
    if (request['method'] is! String) {
      throw new RpcException(error_code.INVALID_REQUEST, 'Request method must '
          'be a string, but was ${JSON.encode(method)}.');
    }

    var params = request['params'];
    if (request.containsKey('params') && params is! List && params is! Map) {
      throw new RpcException(error_code.INVALID_REQUEST, 'Request params must '
          'be an Array or an Object, but was ${JSON.encode(params)}.');
    }

    var id = request['id'];
    if (id != null && id is! String && id is! num) {
      throw new RpcException(error_code.INVALID_REQUEST, 'Request id must be a '
          'string, number, or null, but was ${JSON.encode(id)}.');
    }
  }

  /// Try all the fallback methods in order.
  Future _tryFallbacks(Parameters params) {
    var iterator = _fallbacks.toList().iterator;

    _tryNext() async {
      if (!iterator.moveNext()) {
        throw new RpcException.methodNotFound(params.method);
      }

      try {
        return iterator.current(params);
      } on RpcException catch (error) {
        if (error is! RpcException) throw error;
        if (error.code != error_code.METHOD_NOT_FOUND) throw error;
        return _tryNext();
      }
    }

    return _tryNext();
  }
}
