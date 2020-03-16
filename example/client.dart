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
  await client.sendRequest('count')
      .then((result) => print('Count is $result.'));

  // Parameters are passed as a simple Map or, for positional parameters, an
  // Iterable. Make sure they're JSON-serializable!
  await client.sendRequest('echo', {'message': 'hello'})
      .then((echo) => print('Echo says "$echo"!'));

  // A notification is a way to call a method that tells the server that no
  // result is expected. Its return type is `void`; even if it causes an
  // error, you won't hear back.
  client.sendNotification('count');

  // If the server sends an error response, the returned Future will complete
  // with an RpcException. You can catch this error and inspect its error
  // code, message, and any data that the server sent along with it.
  await client.sendRequest('divide', {'dividend': 2, 'divisor': 0})
      .catchError((error) => print('RPC error ${error.code}: ${error.message}'));
}
