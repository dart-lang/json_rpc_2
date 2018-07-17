// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;
import 'package:json_rpc_2/error_code.dart' as error_code;

/// A controller used to test a [json_rpc.Server].
class ServerController {
  /// The controller for the server's request stream.
  final _requestController = new StreamController<String>();

  /// The controller for the server's response sink.
  final _responseController = new StreamController<String>();

  /// The server.
  json_rpc.Server get server => _server;
  json_rpc.Server _server;

  ServerController() {
    _server = new json_rpc.Server(
        new StreamChannel(_requestController.stream, _responseController.sink));
    _server.listen();
  }

  /// Passes [request], a decoded request, to [server] and returns its decoded
  /// response.
  Future handleRequest(request) =>
      handleJsonRequest(jsonEncode(request)).then(jsonDecode);

  /// Passes [request], a JSON-encoded request, to [server] and returns its
  /// encoded response.
  Future<String> handleJsonRequest(String request) {
    _requestController.add(request);
    return _responseController.stream.first;
  }
}

/// Expects that [controller]'s server will return an error response to
/// [request] with the given [errorCode], [message], and [data].
void expectErrorResponse(
    ServerController controller, request, int errorCode, String message,
    {data}) {
  var id;
  if (request is Map) id = request['id'];
  if (data == null) data = {'request': request};

  expect(
      controller.handleRequest(request),
      completion(equals({
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': errorCode, 'message': message, 'data': data}
      })));
}

/// Returns a matcher that matches a [json_rpc.RpcException] with an
/// `invalid_params` error code.
Matcher throwsInvalidParams(String message) {
  return throwsA(predicate((error) {
    expect(error, new TypeMatcher<json_rpc.RpcException>());
    expect(error.code, equals(error_code.INVALID_PARAMS));
    expect(error.message, equals(message));
    return true;
  }));
}
