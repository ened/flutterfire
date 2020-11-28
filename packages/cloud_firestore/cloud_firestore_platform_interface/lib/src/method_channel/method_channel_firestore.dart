// Copyright 2017, the Chromium project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:async';

import 'package:cloud_firestore_platform_interface/cloud_firestore_platform_interface.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/services.dart';

import 'method_channel_collection_reference.dart';
import 'method_channel_document_reference.dart';
import 'method_channel_query.dart';
import 'method_channel_transaction.dart';
import 'method_channel_write_batch.dart';
import 'utils/firestore_message_codec.dart';
import 'utils/exception.dart';

/// The entry point for accessing a Firestore.
///
/// You can get an instance by calling [FirebaseFirestore.instance].
class MethodChannelFirebaseFirestore extends FirebaseFirestorePlatform {
  /// Create an instance of [MethodChannelFirebaseFirestore] with optional [FirebaseApp]
  MethodChannelFirebaseFirestore({FirebaseApp app}) : super(appInstance: app);

  static int _methodChannelHandleId = 0;

  /// The [Settings] for this [MethodChannelFirebaseFirestore] instance.
  Settings _settings = Settings();

  /// Increments and returns the next channel ID handler for Firestore.
  static int get nextMethodChannelHandleId => _methodChannelHandleId++;

  /// Attach a [FirebaseException] to a given [StreamController].
  static void forwardErrorToController(
      StreamController controller, Map<dynamic, dynamic> arguments) async {
    if (controller == null) {
      return;
    }

    if (arguments['error'] is Map) {
      // Map means its an error from Native.
      Map<String, dynamic> errorMap =
          Map<String, dynamic>.from(arguments['error']);

      FirebaseException exception = FirebaseException(
        plugin: 'cloud_firestore',
        code: errorMap['code'],
        message: errorMap['message'],
      );
      controller.addError(exception);
    } else {
      // A non-map value means the error occurred in Dart, e.g. a type conversion issue,
      // this means it is most likely a library issue that should be reported so
      // it can be fixed.
      controller.addError(arguments['error']);
    }
  }

  /// The [FirebaseApp] instance to which this [FirebaseDatabase] belongs.
  ///
  /// If null, the default [FirebaseApp] is used.

  /// The [MethodChannel] used to communicate with the native plugin
  static MethodChannel channel = MethodChannel(
    'plugins.flutter.io/firebase_firestore',
    StandardMethodCodec(FirestoreMessageCodec()),
  );

  /// The [EventChannel] used for query snapshots
  static EventChannel querySnapshotChannel = EventChannel(
    'plugins.flutter.io/firebase_firestore/query',
    StandardMethodCodec(FirestoreMessageCodec()),
  );

  /// The [EventChannel] used for document snapshots
  static EventChannel documentSnapshotChannel = EventChannel(
    'plugins.flutter.io/firebase_firestore/document',
    StandardMethodCodec(FirestoreMessageCodec()),
  );

  /// The [EventChannel] used for snapshotsInSync
  static EventChannel snapshotsInSyncChannel = EventChannel(
    'plugins.flutter.io/firebase_firestore/snapshotsInSync',
    StandardMethodCodec(FirestoreMessageCodec()),
  );

  /// Gets a [FirebaseFirestorePlatform] with specific arguments such as a different
  /// [FirebaseApp].
  @override
  FirebaseFirestorePlatform delegateFor({FirebaseApp app}) {
    return MethodChannelFirebaseFirestore(app: app);
  }

  @override
  WriteBatchPlatform batch() => MethodChannelWriteBatch(this);

  @override
  Future<void> clearPersistence() async {
    try {
      await channel
          .invokeMethod<void>('Firestore#clearPersistence', <String, dynamic>{
        'firestore': this,
      });
    } catch (e) {
      throw convertPlatformException(e);
    }
  }

  @override
  Future<void> enablePersistence(
      [PersistenceSettings persistenceSettings]) async {
    throw UnimplementedError(
        'enablePersistence() is only available for Web. Use [Settings.persistenceEnabled] for other platforms.');
  }

  @override
  CollectionReferencePlatform collection(String path) {
    return MethodChannelCollectionReference(this, path);
  }

  @override
  QueryPlatform collectionGroup(String path) {
    return MethodChannelQuery(this, path, isCollectionGroupQuery: true);
  }

  @override
  Future<void> disableNetwork() async {
    try {
      await channel
          .invokeMethod<void>('Firestore#disableNetwork', <String, dynamic>{
        'firestore': this,
      });
    } catch (e) {
      throw convertPlatformException(e);
    }
  }

  @override
  DocumentReferencePlatform doc(String path) {
    return MethodChannelDocumentReference(this, path);
  }

  @override
  Future<void> enableNetwork() async {
    try {
      await channel
          .invokeMethod<void>('Firestore#enableNetwork', <String, dynamic>{
        'firestore': this,
      });
    } catch (e) {
      throw convertPlatformException(e);
    }
  }

  @override
  Stream<void> snapshotsInSync() {
    int handle = MethodChannelFirebaseFirestore.nextMethodChannelHandleId;

    StreamSubscription<dynamic> querySnapshotStream;
    StreamController<void> controller; // ignore: close_sinks

    controller = StreamController<void>.broadcast(
      onListen: () async {
        querySnapshotStream = MethodChannelFirebaseFirestore
            .snapshotsInSyncChannel
            .receiveBroadcastStream(
          <String, dynamic>{
            'handle': handle,
            'firestore': this,
          },
        ).listen((event) {
          if (event.containsKey('error')) {
            MethodChannelFirebaseFirestore.forwardErrorToController(
              controller,
              event,
            );
          } else {
            controller.add(null);
          }
        }, onError: (error, stack) {
          // TODO: Handle these conditions
        });
      },
      onCancel: () {
        querySnapshotStream?.cancel();
      },
    );

    return controller.stream;
  }

  @override
  Future<T> runTransaction<T>(
    TransactionHandler<T> transactionHandler, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    assert(timeout.inMilliseconds > 0,
        'Transaction timeout must be more than 0 milliseconds');

    final String transactionId =
        await MethodChannelFirebaseFirestore.channel.invokeMethod<String>(
      'Transaction#create',
    );

    StreamSubscription<dynamic> snapshotStream;

    Completer<T> completer = Completer();

    // Will be set by the `transactionHandler`.
    dynamic result;

    final eventChannel = EventChannel(
      'plugins.flutter.io/firebase_firestore/transaction/$transactionId',
      StandardMethodCodec(FirestoreMessageCodec()),
    );

    snapshotStream = eventChannel.receiveBroadcastStream(
      <String, dynamic>{'firestore': this, 'timeout': timeout.inMilliseconds},
    ).listen(
      (event) async {
        if (event['error'] != null) {
          completer.completeError(
            FirebaseException(
              plugin: 'cloud_firestore',
              code: event['error']['code'],
              message: event['error']['message'],
            ),
          );
          return;
        } else if (event['complete'] == true) {
          completer.complete(result);
          return;
        }

        final TransactionPlatform transaction =
            MethodChannelTransaction(transactionId, event["appName"]);

        // If the transaction fails on Dart side, then forward the error
        // right away and only inform native side of the error.
        try {
          result = await transactionHandler(transaction);
        } catch (error) {
          // Signal native that a user error occurred, and finish the
          // transaction
          await MethodChannelFirebaseFirestore.channel
              .invokeMethod('Transaction#storeResult', <String, dynamic>{
            'transactionId': transactionId,
            'result': {
              'type': 'ERROR',
            }
          });

          // Allow the [runTransaction] method to listen to an error.
          completer.completeError(error);

          return;
        }

        // Send the transaction commands to Dart.
        await MethodChannelFirebaseFirestore.channel
            .invokeMethod('Transaction#storeResult', <String, dynamic>{
          'transactionId': transactionId,
          'result': {
            'type': 'SUCCESS',
            'commands': transaction.commands,
          },
        });
      },
    );

    return completer.future.whenComplete(() {
      snapshotStream?.cancel();
    });
  }

  @override
  Settings get settings {
    return _settings;
  }

  @override
  set settings(Settings settings) {
    _settings = settings;
  }

  @override
  Future<void> terminate() async {
    try {
      await channel.invokeMethod<void>('Firestore#terminate', <String, dynamic>{
        'firestore': this,
      });
    } catch (e) {
      throw convertPlatformException(e);
    }
  }

  @override
  Future<void> waitForPendingWrites() async {
    try {
      await channel.invokeMethod<void>(
          'Firestore#waitForPendingWrites', <String, dynamic>{
        'firestore': this,
      });
    } catch (e) {
      throw convertPlatformException(e);
    }
  }
}
