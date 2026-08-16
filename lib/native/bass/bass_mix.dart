import 'dart:ffi' as ffi;

const int bassMixerQueue = 0x8000;
const int bassMixerEnd = 0x10000;
const int bassMixerResume = 0x1000;
const int bassMixerPosex = 0x2000;
const int bassMixerChanAbsolute = 0x1000;
const int bassMixerChanDownmix = 0x400000;
const int bassMixerChanNoRampIn = 0x800000;
const int bassStreamAutofree = 0x40000;
const int bassSyncMixerQueue = 0x10202;
const int bassSyncMixerEnvelope = 0x10200;
const int bassSyncMixerEnvelopeNode = 0x10201;
const int bassSyncPos = 0x00;
const int bassSyncOnetime = 0x80000000;
const int bassMixerEnvVol = 2;
const int bassPosMixerReset = 0x10000;

typedef BassSyncProc =
    ffi.Void Function(
      ffi.Uint32 handle,
      ffi.Uint32 channel,
      ffi.Uint32 data,
      ffi.Pointer<ffi.Void> user,
    );

class BassMix {
  BassMix(ffi.DynamicLibrary dynamicLibrary) : _lib = dynamicLibrary;

  final ffi.DynamicLibrary _lib;

  late final _getVersion = _lib
      .lookup<ffi.NativeFunction<ffi.Uint32 Function()>>(
        'BASS_Mixer_GetVersion',
      )
      .asFunction<int Function()>();

  late final _streamCreate = _lib
      .lookup<
        ffi.NativeFunction<
          ffi.Uint32 Function(ffi.Uint32, ffi.Uint32, ffi.Uint32)
        >
      >('BASS_Mixer_StreamCreate')
      .asFunction<int Function(int, int, int)>();

  late final _streamAddChannel = _lib
      .lookup<
        ffi.NativeFunction<
          ffi.Int32 Function(ffi.Uint32, ffi.Uint32, ffi.Uint32)
        >
      >('BASS_Mixer_StreamAddChannel')
      .asFunction<int Function(int, int, int)>();

  late final _streamAddChannelEx = _lib
      .lookup<
        ffi.NativeFunction<
          ffi.Int32 Function(
            ffi.Uint32,
            ffi.Uint32,
            ffi.Uint32,
            ffi.Uint64,
            ffi.Uint64,
          )
        >
      >('BASS_Mixer_StreamAddChannelEx')
      .asFunction<int Function(int, int, int, int, int)>();

  late final _channelGetPosition = _lib
      .lookup<ffi.NativeFunction<ffi.Uint64 Function(ffi.Uint32, ffi.Uint32)>>(
        'BASS_Mixer_ChannelGetPosition',
      )
      .asFunction<int Function(int, int)>();

  late final _channelSetPosition = _lib
      .lookup<
        ffi.NativeFunction<
          ffi.Int32 Function(ffi.Uint32, ffi.Uint64, ffi.Uint32)
        >
      >('BASS_Mixer_ChannelSetPosition')
      .asFunction<int Function(int, int, int)>();

  late final _channelRemove = _lib
      .lookup<ffi.NativeFunction<ffi.Int32 Function(ffi.Uint32)>>(
        'BASS_Mixer_ChannelRemove',
      )
      .asFunction<int Function(int)>();

  int getVersion() => _getVersion();

  int streamCreate(int frequency, int channels, int flags) =>
      _streamCreate(frequency, channels, flags);

  bool streamAddChannel(int mixer, int channel, int flags) =>
      _streamAddChannel(mixer, channel, flags) != 0;

  bool streamAddChannelEx(
    int mixer,
    int channel,
    int flags,
    int start,
    int length,
  ) => _streamAddChannelEx(mixer, channel, flags, start, length) != 0;

  int channelGetPosition(int channel, int mode) =>
      _channelGetPosition(channel, mode);

  bool channelSetPosition(int channel, int position, int mode) =>
      _channelSetPosition(channel, position, mode) != 0;

  bool channelRemove(int channel) => _channelRemove(channel) != 0;

  late final _channelSetEnvelope = _lib
      .lookup<
        ffi.NativeFunction<
          ffi.Int32 Function(
            ffi.Uint32,
            ffi.Uint32,
            ffi.Pointer<BassMixNode>,
            ffi.Uint32,
          )
        >
      >('BASS_Mixer_ChannelSetEnvelope')
      .asFunction<int Function(int, int, ffi.Pointer<BassMixNode>, int)>();

  bool channelSetEnvelope(
    int channel,
    int type,
    ffi.Pointer<BassMixNode> nodes,
    int count,
  ) => _channelSetEnvelope(channel, type, nodes, count) != 0;

  late final _channelSetSync = _lib
      .lookup<
        ffi.NativeFunction<
          ffi.Uint32 Function(
            ffi.Uint32,
            ffi.Uint32,
            ffi.Uint64,
            ffi.Pointer<ffi.NativeFunction<BassSyncProc>>,
            ffi.Pointer<ffi.Void>,
          )
        >
      >('BASS_Mixer_ChannelSetSync')
      .asFunction<
        int Function(
          int,
          int,
          int,
          ffi.Pointer<ffi.NativeFunction<BassSyncProc>>,
          ffi.Pointer<ffi.Void>,
        )
      >();

  int channelSetSync(
    int channel,
    int type,
    int param,
    ffi.Pointer<ffi.NativeFunction<BassSyncProc>> callback,
    ffi.Pointer<ffi.Void> user,
  ) => _channelSetSync(channel, type, param, callback, user);

  late final _channelRemoveSync = _lib
      .lookup<ffi.NativeFunction<ffi.Int32 Function(ffi.Uint32, ffi.Uint32)>>(
        'BASS_Mixer_ChannelRemoveSync',
      )
      .asFunction<int Function(int, int)>();

  bool channelRemoveSync(int channel, int sync) =>
      _channelRemoveSync(channel, sync) != 0;

  late final _channelGetPositionEx = _lib
      .lookup<
        ffi.NativeFunction<
          ffi.Uint64 Function(ffi.Uint32, ffi.Uint32, ffi.Uint32)
        >
      >('BASS_Mixer_ChannelGetPositionEx')
      .asFunction<int Function(int, int, int)>();

  int channelGetPositionEx(int channel, int mode, int delay) =>
      _channelGetPositionEx(channel, mode, delay);
}

final class BassMixNode extends ffi.Struct {
  @ffi.Uint64()
  external int position;

  @ffi.Float()
  external double value;
}

final class BassChannelInfo extends ffi.Struct {
  @ffi.Uint32()
  external int frequency;

  @ffi.Uint32()
  external int channels;

  @ffi.Uint32()
  external int flags;

  @ffi.Uint32()
  external int type;

  @ffi.Uint32()
  external int originalResolution;

  @ffi.Uint32()
  external int plugin;

  @ffi.Uint32()
  external int sample;

  external ffi.Pointer<ffi.Char> filename;
}

class BassChannel {
  BassChannel(ffi.DynamicLibrary dynamicLibrary) : _lib = dynamicLibrary;

  final ffi.DynamicLibrary _lib;

  late final _getInfo = _lib
      .lookup<
        ffi.NativeFunction<
          ffi.Int32 Function(ffi.Uint32, ffi.Pointer<BassChannelInfo>)
        >
      >('BASS_ChannelGetInfo')
      .asFunction<int Function(int, ffi.Pointer<BassChannelInfo>)>();

  bool getInfo(int channel, ffi.Pointer<BassChannelInfo> info) =>
      _getInfo(channel, info) != 0;
}

class BassSync {
  BassSync(ffi.DynamicLibrary dynamicLibrary) : _lib = dynamicLibrary;

  final ffi.DynamicLibrary _lib;

  late final _channelSetSync = _lib
      .lookup<
        ffi.NativeFunction<
          ffi.Uint32 Function(
            ffi.Uint32,
            ffi.Uint32,
            ffi.Uint64,
            ffi.Pointer<ffi.NativeFunction<BassSyncProc>>,
            ffi.Pointer<ffi.Void>,
          )
        >
      >('BASS_ChannelSetSync')
      .asFunction<
        int Function(
          int,
          int,
          int,
          ffi.Pointer<ffi.NativeFunction<BassSyncProc>>,
          ffi.Pointer<ffi.Void>,
        )
      >();

  int channelSetSync(
    int channel,
    int type,
    int param,
    ffi.Pointer<ffi.NativeFunction<BassSyncProc>> callback,
    ffi.Pointer<ffi.Void> user,
  ) => _channelSetSync(channel, type, param, callback, user);

  late final _channelRemoveSync = _lib
      .lookup<ffi.NativeFunction<ffi.Int32 Function(ffi.Uint32, ffi.Uint32)>>(
        'BASS_ChannelRemoveSync',
      )
      .asFunction<int Function(int, int)>();

  bool channelRemoveSync(int channel, int sync) =>
      _channelRemoveSync(channel, sync) != 0;
}
