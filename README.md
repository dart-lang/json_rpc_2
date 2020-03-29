A library that implements the [JSON-RPC 2.0 spec][spec].

[spec]: http://www.jsonrpc.org/specification

## Server

A JSON-RPC 2.0 server exposes a set of methods that can be called by clients.
These methods can be registered using `Server.registerMethod`:

```dart
import 'dart:async';
import 'dart:io';

import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;
import 'package:web_socket_channel/io.dart';

Future<void> main() async {
  final server = await HttpServer.bind('localhost', 4321);
  server.listen((HttpRequest request) async {
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
```

## Client

A JSON-RPC 2.0 client calls methods on a server and handles the server's
responses to those method calls. These methods can be called using
`Client.sendRequest`:

```dart
import 'dart:async';

import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;
import 'package:pedantic/pedantic.dart';
import 'package:web_socket_channel/io.dart';

Future main() async {
  final channel = IOWebSocketChannel.connect('ws://localhost:4321');
  final client = json_rpc.Client(channel.cast<String>());

  // The client won't subscribe to the input stream until you call `listen`.
  unawaited(
    client.listen(),
  );

  // This calls the "count" method on the server. A Future is returned that
  // will complete to the value contained in the server's response.
  await client
      .sendRequest('count')
      .then((result) => print('Count is $result.'));

  // Parameters are passed as a simple Map or, for positional parameters, an
  // Iterable. Make sure they're JSON-serializable!
  await client.sendRequest(
      'echo', {'message': 'hello'}).then((echo) => print('Echo says "$echo"!'));

  // A notification is a way to call a method that tells the server that no
  // result is expected. Its return type is `void`; even if it causes an
  // error, you won't hear back.
  client.sendNotification('count');

  // If the server sends an error response, the returned Future will complete
  // with an RpcException. You can catch this error and inspect its error
  // code, message, and any data that the server sent along with it.
  await client.sendRequest('divide', {'dividend': 2, 'divisor': 0}).catchError(
      (error) => print('RPC error ${error.code}: ${error.message}'));
}
```

## Peer

Although JSON-RPC 2.0 only explicitly describes clients and servers, it also
mentions that two-way communication can be supported by making each endpoint
both a client and a server. This package supports this directly using the `Peer`
class, which implements both `Client` and `Server`. It supports the same methods
as those classes, and automatically makes sure that every message from the other
endpoint is routed and handled correctly.
