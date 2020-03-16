import 'dart:async';
import 'dart:io';

import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;
import 'package:web_socket_channel/io.dart';

Future<void> main() async {
  final httpServer = await HttpServer.bind('localhost', 4321);
  httpServer.listen((HttpRequest request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    final channel = IOWebSocketChannel(socket);

    // The channel is a StreamChannel<dynamic> because it might emit binary
    // List<int>s, but JSON RPC 2 only works with Strings so we assert it only
    // emits those by casting it.
    final server = json_rpc.Server(channel.cast<String>());

    // Any string may be used as a method name. JSON-RPC 2.0 methods are
    // case-sensitive.
    var i = 0;
    server.registerMethod('count', () {
      // Just return the value to be sent as a response to the client. This can
      // be anything JSON-serializable, or a Future that completes to something
      // JSON-serializable.
      return ++i;
    });

    // Methods can take parameters. They're presented as a [Parameters] object
    // which makes it easy to validate that the expected parameters exist.
    server.registerMethod('echo', (json_rpc.Parameters params) {
      // If the request doesn't have a "message" parameter, this will
      // automatically send a response notifying the client that the request
      // was invalid.
      return params['message'].asString;
    });

    // [Parameters] has methods for verifying argument types.
    server.registerMethod('subtract', (json_rpc.Parameters params) {
      // If "minuend" or "subtrahend" aren't numbers, this will reject the
      // request.
      return params['minuend'].asNum - params['subtrahend'].asNum;
    });

    // [Parameters] also supports optional arguments.
    server.registerMethod('sort', (json_rpc.Parameters params) {
      final list = params['list'].asList;
      list.sort();
      if (params['descending'].asBoolOr(false)) {
        return list.reversed.toList();
      } else {
        return list;
      }
    });

    // A method can send an error response by throwing a
    // `json_rpc.RpcException`. Any positive number may be used as an
    // application- defined error code.
    const DIVIDE_BY_ZERO = 1;
    server.registerMethod('divide', (json_rpc.Parameters params) {
      final divisor = params['divisor'].asNum;
      if (divisor == 0) {
        throw json_rpc.RpcException(DIVIDE_BY_ZERO, 'Cannot divide by zero.');
      }

      return params['dividend'].asNum / divisor;
    });

    // To give you time to register all your methods, the server won't actually
    // start listening for requests until you call `listen`.
    await server.listen();
  });
}
