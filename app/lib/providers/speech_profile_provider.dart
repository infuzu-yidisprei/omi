import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_provider_utilities/flutter_provider_utilities.dart';
import 'package:friend_private/backend/http/api/speech_profile.dart';
import 'package:friend_private/backend/http/api/users.dart';
import 'package:friend_private/backend/http/cloud_storage.dart';
import 'package:friend_private/backend/preferences.dart';
import 'package:friend_private/backend/schema/bt_device.dart';
import 'package:friend_private/backend/schema/memory.dart';
import 'package:friend_private/backend/schema/message_event.dart';
import 'package:friend_private/backend/schema/structured.dart';
import 'package:friend_private/backend/schema/transcript_segment.dart';
import 'package:friend_private/providers/capture_provider.dart';
import 'package:friend_private/providers/device_provider.dart';
import 'package:friend_private/services/devices.dart';
import 'package:friend_private/services/services.dart';
import 'package:friend_private/utils/audio/wav_bytes.dart';
import 'package:friend_private/utils/memories/process.dart';
import 'package:friend_private/utils/pure_socket.dart';
import 'package:uuid/uuid.dart';

class SpeechProfileProvider extends ChangeNotifier
    with MessageNotifierMixin
    implements IDeviceServiceSubsciption, ITransctipSegmentSocketServiceListener {
  DeviceProvider? deviceProvider;
  bool? permissionEnabled;
  bool loading = false;
  BTDeviceStruct? device;

  final targetWordsCount = 70;
  final maxDuration = 90;
  StreamSubscription<OnConnectionStateChangedEvent>? connectionStateListener;
  List<TranscriptSegment> segments = [];
  double? streamStartedAtSecond;
  WavBytesUtil audioStorage = WavBytesUtil(codec: BleAudioCodec.opus);
  StreamSubscription? _bleBytesStream;

  TranscripSegmentSocketService? _socket;

  bool startedRecording = false;
  double percentageCompleted = 0;
  bool uploadingProfile = false;
  bool profileCompleted = false;
  Timer? forceCompletionTimer;

  bool isInitialising = false;
  bool isInitialised = false;

  String text = '';
  String message = '';

  late bool _isFromOnboarding;

  /// only used during onboarding /////
  String loadingText = 'Uploading your voice profile....';
  ServerMemory? memory;

  /////////////////////////////////

  void updateLoadingText(String text) {
    loadingText = text;
    notifyListeners();
  }

  void setInitialising(bool value) {
    isInitialising = value;
    notifyListeners();
  }

  void setInitialised(bool value) {
    isInitialised = value;
    notifyListeners();
  }

  void setProviders(DeviceProvider provider) {
    deviceProvider = provider;
    notifyListeners();
  }

  Future<void> updateDevice() async {
    if (device == null) {
      await deviceProvider?.scanAndConnectToDevice();
      device = deviceProvider?.connectedDevice;
    }
    notifyListeners();
  }

  Future<void> initialise(bool isFromOnboarding) async {
    _isFromOnboarding = isFromOnboarding;
    setInitialising(true);
    device = deviceProvider?.connectedDevice;
    await _initiateWebsocket(force: true);

    if (device != null) await initiateFriendAudioStreaming();
    if (_socket?.state != SocketServiceState.connected) {
      // wait for websocket to connect
      await Future.delayed(Duration(seconds: 2));
    }

    setInitialising(false);
    setInitialised(true);
    // initiateConnectionListener();
    notifyListeners();
  }

  void updateStartedRecording(bool value) {
    startedRecording = value;
    notifyListeners();
  }

  changeLoadingState(bool value) {
    loading = value;
    notifyListeners();
  }

  initiateConnectionListener() async {
    if (device == null || connectionStateListener != null) return;
    ServiceManager.instance().device.subscribe(this, this);
  }

  Future<void> _initiateWebsocket({bool force = false}) async {
    _socket = await ServiceManager.instance()
        .socket
        .speechProfile(codec: BleAudioCodec.opus, sampleRate: 16000, force: force);
    if (_socket == null) {
      throw Exception("Can not create new speech profile socket");
    }
    _socket?.subscribe(this, this);
  }

  _handleCompletion() async {
    if (uploadingProfile || profileCompleted) return;
    String text = segments.map((e) => e.text).join(' ').trim();
    int wordsCount = text.split(' ').length;
    percentageCompleted = (wordsCount / targetWordsCount).clamp(0, 1);
    notifyListeners();
    if (percentageCompleted == 1) {
      await finalize();
    }
    notifyListeners();
  }

  Future finalize() async {
    if (uploadingProfile || profileCompleted) return;

    int duration = segments.isEmpty ? 0 : segments.last.end.toInt();
    if (duration < 5 || duration > 120) {
      notifyError('INVALID_RECORDING');
    }

    String text = segments.map((e) => e.text).join(' ').trim();
    if (text.split(' ').length < (targetWordsCount / 2)) {
      // 25 words
      notifyError('TOO_SHORT');
    }
    uploadingProfile = true;
    notifyListeners();
    await _socket?.stop(reason: 'finalizing');
    forceCompletionTimer?.cancel();
    connectionStateListener?.cancel();
    _bleBytesStream?.cancel();

    updateLoadingText('Memorizing your voice...');
    List<List<int>> raw = List.from(audioStorage.rawPackets);
    var data = await audioStorage.createWavFile(filename: 'speaker_profile.wav');
    try {
      await uploadProfile(data.item1);
      await uploadProfileBytes(raw, duration);
    } catch (e) {}

    updateLoadingText('Personalizing your experience...');
    SharedPreferencesUtil().hasSpeakerProfile = true;
    if (_isFromOnboarding) {
      await createMemory();
	  // TODO: thinh, socket
      //captureProvider?.clearTranscripts();
    }
    uploadingProfile = false;
    profileCompleted = true;
    text = '';
    updateLoadingText("You're all set!");
    notifyListeners();
  }

  // TODO: use connection directly
  Future<StreamSubscription?> _getBleAudioBytesListener(
    String deviceId, {
    required void Function(List<int>) onAudioBytesReceived,
  }) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) {
      return Future.value(null);
    }
    return connection.getBleAudioBytesListener(onAudioBytesReceived: onAudioBytesReceived);
  }

  Future<void> initiateFriendAudioStreaming() async {
    _bleBytesStream = await _getBleAudioBytesListener(
      device!.id,
      onAudioBytesReceived: (List<int> value) {
        if (value.isEmpty) return;
        audioStorage.storeFramePacket(value);

        value.removeRange(0, 3);
        if (_socket?.state == SocketServiceState.connected) {
          _socket?.send(value);
        }
      },
    );
  }

  _validateSingleSpeaker() {
    int speakersCount = segments.map((e) => e.speaker).toSet().length;
    debugPrint('_validateSingleSpeaker speakers count: $speakersCount');
    if (speakersCount > 1) {
      var speakerToWords = segments.fold<Map<int, int>>(
        {},
        (previousValue, element) {
          previousValue[element.speakerId] = (previousValue[element.speakerId] ?? 0) + element.text.split(' ').length;
          return previousValue;
        },
      );
      debugPrint('speakerToWords: $speakerToWords');
      if (speakerToWords.values.every((element) => element / segments.length > 0.2)) {
        notifyError('MULTIPLE_SPEAKERS');
      }
    }
  }

  void resetSegments() {
    segments.clear();
    streamStartedAtSecond = null;
    audioStorage.clearAudioBytes();
    notifyListeners();
  }

  Future setupSpeechRecording() async {
    final permission = await getStoreRecordingPermission();
    permissionEnabled = permission;
    if (permission != null) {
      SharedPreferencesUtil().permissionStoreRecordingsEnabled = permission;
    }
    notifyListeners();
  }

  void updateProgressMessage() {
    text = segments.map((e) => e.text).join(' ').trim();
    int wordsCount = text.split(' ').length;
    message = 'Keep speaking until you get 100%.';
    if (wordsCount > 10) {
      message = 'Keep going, you are doing great';
    } else if (wordsCount > 25) {
      message = 'Great job, you are almost there';
    } else if (wordsCount > 40) {
      message = 'So close, just a little more';
    }
    notifyListeners();
  }

  Future close() async {
    connectionStateListener?.cancel();
    _bleBytesStream?.cancel();
    forceCompletionTimer?.cancel();
    segments.clear();
    text = '';
    startedRecording = false;
    percentageCompleted = 0;
    uploadingProfile = false;
    profileCompleted = false;
    await _socket?.stop(reason: 'closing');
    notifyListeners();
  }

  Future<bool?> createMemory({bool forcedCreation = false}) async {
    debugPrint('_createMemory forcedCreation: $forcedCreation');

    // if (memoryCreating) return null;
    // if (segments.isEmpty && photos.isEmpty) return false;

    // TODO: should clean variables here? and keep them locally?
    // setMemoryCreating(true);
    File? file;
    if (audioStorage.frames.isNotEmpty == true) {
      try {
        file = (await audioStorage.createWavFile(removeLastNSeconds: 0)).item1;
        uploadFile(file);
      } catch (e) {
        print("creating and uploading file error: $e");
      } // in case was a local recording and not a BLE recording
    }

    memory = await processTranscriptContent(
      segments: segments,
      startedAt: null,
      finishedAt: null,
      geolocation: null,
      photos: [],
      triggerIntegrations: true,
      language: SharedPreferencesUtil().recordingsLanguage,
      source: 'speech_profile_onboarding',
    );
    debugPrint(memory.toString());
    if (memory == null && (segments.isNotEmpty)) {
      memory = ServerMemory(
        id: const Uuid().v4(),
        createdAt: DateTime.now(),
        structured: Structured('', '', emoji: '⛓️‍💥', category: 'other'),
        discarded: true,
        transcriptSegments: segments,
        failed: true,
        source: segments.isNotEmpty ? MemorySource.friend : MemorySource.openglass,
        language: segments.isNotEmpty ? SharedPreferencesUtil().recordingsLanguage : null,
      );
      SharedPreferencesUtil().addFailedMemory(memory!);
      // TODO: store anyways something temporal and retry once connected again.
    }

    notifyListeners();
    return true;
  }

  @override
  void dispose() {
    // This won't be called unless the provider is removed from the widget tree. So we need to manually call this in the widget's dispose method.
    connectionStateListener?.cancel();
    _bleBytesStream?.cancel();
    forceCompletionTimer?.cancel();
    _socket?.unsubscribe(this);
    ServiceManager.instance().device.unsubscribe(this);
    super.dispose();
  }

  @override
  void onDeviceConnectionStateChanged(String deviceId, DeviceConnectionState state) async {
    switch (state) {
      case DeviceConnectionState.connected:
        var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
        if (connection == null) {
          return;
        }
        device = connection.device;
        notifyListeners();
        initiateFriendAudioStreaming();
        break;
      case DeviceConnectionState.disconnected:
        if (deviceId == device?.id) {
          device = null;
          notifyListeners();
        }
      default:
        debugPrint("Device connection state is not supported $state");
    }
  }

  @override
  void onDevices(List<BTDeviceStruct> devices) {}

  @override
  void onStatusChanged(DeviceServiceStatus status) {}

  @override
  void onClosed() {
    // TODO: implement onClosed
  }

  @override
  void onError(Object err) {
    notifyError('WS_ERR');
  }

  @override
  void onMessageEventReceived(ServerMessageEvent event) {
    // TODO: implement onMessageEventReceived
  }

  @override
  void onSegmentReceived(List<TranscriptSegment> newSegments) {
    if (newSegments.isEmpty) return;
    if (segments.isEmpty) {
      audioStorage.removeFramesRange(fromSecond: 0, toSecond: newSegments[0].start.toInt());
    }
    streamStartedAtSecond ??= newSegments[0].start;

    TranscriptSegment.combineSegments(
      segments,
      newSegments,
      toRemoveSeconds: streamStartedAtSecond ?? 0,
    );
    updateProgressMessage();
    _validateSingleSpeaker();
    _handleCompletion();
    notifyInfo('SCROLL_DOWN');
    debugPrint('Memory creation timer restarted');
  }
}
