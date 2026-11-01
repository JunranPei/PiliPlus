import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/model_hot_video_item.dart';
import 'package:PiliPlus/pages/common/common_list_controller.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:get/get.dart';

class RelatedController
    extends CommonListController<List<HotVideoItemModel>?, HotVideoItemModel> {
  RelatedController({this.autoQuery = true});
  String bvid = Get.arguments['bvid'];
  final bool autoQuery;

  @override
  void onInit() {
    super.onInit();
    if (autoQuery) {
      if (const bool.fromEnvironment('DEFER_VIDEO_AUXILIARY')) {
        _queryAfterStartup();
      } else {
        queryData();
      }
    }
  }

  Future<void> _queryAfterStartup() async {
    final tag = Get.arguments['heroTag'] as String?;
    if (Get.isRegistered<VideoDetailController>(tag: tag)) {
      final video = Get.find<VideoDetailController>(tag: tag);
      if (!await video.waitForAuxiliaryRequest('related')) return;
    }
    if (!isClosed) await queryData();
  }

  @override
  Future<LoadingState<List<HotVideoItemModel>?>> customGetData() =>
      VideoHttp.relatedVideoList(bvid: bvid);
}
