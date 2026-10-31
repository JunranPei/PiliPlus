import 'package:PiliPlus/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:PiliPlus/grpc/grpc_req.dart';
import 'package:PiliPlus/grpc/grpc_decode.dart';
import 'package:PiliPlus/grpc/url.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/plugin/pl_player/playback/playback_diagnostics.dart';
import 'package:fixnum/fixnum.dart';

abstract final class DmGrpc {
  static const _parseWorker = bool.fromEnvironment('STARTUP_DM_PARSE_WORKER');
  static int _requestSequence = 0;

  static Future<LoadingState<DmSegMobileReply>> dmSegMobile({
    required int cid,
    required int segmentIndex,
    int type = 1,
  }) {
    const trace = PlaybackDiagnostics.enabled;
    final requestId = trace ? ++_requestSequence : 0;
    final context = <String, Object?>{
      'dmRequestId': requestId,
      'cid': cid,
      'segmentIndex': segmentIndex,
    };
    if (trace) PlaybackDiagnostics.event('dm.request.begin', context);
    return GrpcReq.request(
      GrpcUrl.dmSegMobile,
      DmSegMobileReq(
        oid: Int64(cid),
        segmentIndex: Int64(segmentIndex),
        type: type,
      ),
      DmSegMobileReply.fromBuffer,
      isolate: true,
      isolateThresholdBytes: _parseWorker
          ? 16 * 1024
          : GrpcDecode.defaultThreshold,
      onParseTiming: trace
          ? (timing) => PlaybackDiagnostics.event('dm.parse.end', {
              ...context,
              ...timing,
            })
          : null,
    );
  }

  static Future<LoadingState<DmViewReply>> dmView(int aid, int cid) {
    return GrpcReq.request(
      GrpcUrl.dmView,
      DmViewReq(pid: Int64(aid), oid: Int64(cid), type: 1),
      DmViewReply.fromBuffer,
    );
  }
}
