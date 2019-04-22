#include "oneflow/core/kernel/yolo_box_diff_kernel.h"

namespace oneflow {

namespace {

template<typename T>
__global__ void CoordinateTransformGpu(const int32_t box_num, const T* bbox,
                                       const int32_t* anchor_boxes_size_ptr,
                                       const int32_t* box_mask_ptr, T* pred_bbox,
                                       const int32_t layer_height, const int32_t layer_width,
                                       const int32_t image_height, const int32_t image_width,
                                       const int32_t layer_nbox) {
  CUDA_1D_KERNEL_LOOP(i, box_num) {
    // n=4*1083 or 4*4332 or 4*17328
    const int32_t iw = (i / layer_nbox) % layer_width;
    const int32_t ih = (i / layer_nbox) / layer_width;
    const int32_t ibox = box_mask_ptr[i % layer_nbox];
    pred_bbox[4 * i + 0] = (bbox[4 * i + 0] + iw) / static_cast<T>(layer_width);
    pred_bbox[4 * i + 1] = (bbox[4 * i + 1] + ih) / static_cast<T>(layer_height);
    pred_bbox[4 * i + 2] =
        exp(bbox[4 * i + 2]) * anchor_boxes_size_ptr[2 * ibox] / static_cast<T>(image_width);
    pred_bbox[4 * i + 3] =
        exp(bbox[4 * i + 3]) * anchor_boxes_size_ptr[2 * ibox + 1] / static_cast<T>(image_height);
  }
}

template<typename T>
__global__ void CalcIouGpuold(const int32_t box_num, const T* pred_bbox, float* overlaps,
                              const int32_t gt_max_num, const int32_t gt_idx, const float gt_left,
                              const float gt_right, const float gt_bottom, const float gt_top,
                              const float gt_area) {
  CUDA_1D_KERNEL_LOOP(i, box_num) {
    const float box_left = pred_bbox[i * 4] - 0.5f * pred_bbox[i * 4 + 2];
    const float box_right = pred_bbox[i * 4] + 0.5f * pred_bbox[i * 4 + 2];
    const float box_bottom = pred_bbox[i * 4 + 1] + 0.5f * pred_bbox[i * 4 + 3];
    const float box_top = pred_bbox[i * 4 + 1] - 0.5f * pred_bbox[i * 4 + 3];

    float left = box_left > gt_left ? box_left : gt_left;
    float right = box_right < gt_right ? box_right : gt_right;
    const float iw = min(box_right, gt_right) - max(gt_left, box_left);
    const float ih = min(box_bottom, gt_bottom) - max(box_top, gt_top);
    const float inter = iw * ih;
    overlaps[i * gt_max_num + gt_idx] =
        inter / (pred_bbox[i * 4 + 2] * pred_bbox[i * 4 + 3] + gt_area - inter);
  }
}

template<typename T>
__global__ void CalcIouGpu(const int32_t box_num, const T* pred_bbox, const T* gt_boxes_ptr,
                           float* overlaps, const int32_t gt_max_num, const int32_t gt_valid_num) {
  CUDA_1D_KERNEL_LOOP(i, box_num * gt_valid_num) {
    const int32_t box_index = i / gt_valid_num;
    const int32_t gt_index = i % gt_valid_num;
    const float gt_left = gt_boxes_ptr[gt_index * 4] - 0.5f * gt_boxes_ptr[gt_index * 4 + 2];
    const float gt_right = gt_boxes_ptr[gt_index * 4] + 0.5f * gt_boxes_ptr[gt_index * 4 + 2];
    const float gt_top = gt_boxes_ptr[gt_index * 4 + 1] - 0.5f * gt_boxes_ptr[gt_index * 4 + 3];
    const float gt_bottom = gt_boxes_ptr[gt_index * 4 + 1] + 0.5f * gt_boxes_ptr[gt_index * 4 + 3];
    const float gt_area = gt_boxes_ptr[gt_index * 4 + 2] * gt_boxes_ptr[gt_index * 4 + 3];

    const float box_left = pred_bbox[box_index * 4] - 0.5f * pred_bbox[box_index * 4 + 2];
    const float box_right = pred_bbox[box_index * 4] + 0.5f * pred_bbox[box_index * 4 + 2];
    const float box_top = pred_bbox[box_index * 4 + 1] - 0.5f * pred_bbox[box_index * 4 + 3];
    const float box_bottom = pred_bbox[box_index * 4 + 1] + 0.5f * pred_bbox[box_index * 4 + 3];
    const float iw = min(box_right, gt_right) - max(gt_left, box_left);
    const float ih = min(box_bottom, gt_bottom) - max(box_top, gt_top);
    const float inter = iw * ih;
    if (iw < 0 || ih < 0) {
      overlaps[box_index * gt_max_num + gt_index] = 0.0f;
    } else {
      overlaps[box_index * gt_max_num + gt_index] =
          inter / (pred_bbox[box_index * 4 + 2] * pred_bbox[box_index * 4 + 3] + gt_area - inter);
    }
  }
}

__global__ void SetMaxOverlapsAndGtIndex(const int32_t box_num, const int32_t gt_valid_num,
                                         const int32_t gt_max_num, const float* overlaps,
                                         float* max_overlaps, int32_t* max_overlaps_gt_indices,
                                         const float ignore_thresh, const float truth_thresh) {
  CUDA_1D_KERNEL_LOOP(i, box_num) {
    max_overlaps[i] = 0.0f;
    max_overlaps_gt_indices[i] = -1;
    for (int j = 0; j < gt_valid_num; j++) {
      if (overlaps[i * gt_max_num + j] > max_overlaps[i]) {
        max_overlaps[i] = overlaps[i * gt_max_num + j];
        if (overlaps[i * gt_max_num + j] <= ignore_thresh) {
          max_overlaps_gt_indices[i] = -1;
        }  // negative
        else if (overlaps[i * gt_max_num + j] > truth_thresh) {
          max_overlaps_gt_indices[i] = j;
        }  // postive
        else {
          max_overlaps_gt_indices[i] = -2;
        }
      }
    }
  }
}

template<typename T>
__global__ void CalcGtNearestAnchorSize(const int32_t gt_valid_num, const T* gt_boxes_ptr,
                                        const int32_t* anchor_boxes_size_ptr,
                                        const int32_t* box_mask_ptr,
                                        int32_t* max_overlaps_gt_indices,
                                        const int32_t anchor_boxes_size_num,
                                        const int32_t box_mask_num, const int32_t layer_height,
                                        const int32_t layer_width, const int32_t layer_nbox,
                                        const int32_t image_height, const int32_t image_width) {
  CUDA_1D_KERNEL_LOOP(i, gt_valid_num) {
    const float gt_left = 0 - 0.5f * gt_boxes_ptr[i * 4 + 2];
    const float gt_right = 0 + 0.5f * gt_boxes_ptr[i * 4 + 2];
    const float gt_bottom = 0 + 0.5f * gt_boxes_ptr[i * 4 + 3];
    const float gt_top = 0 - 0.5f * gt_boxes_ptr[i * 4 + 3];
    const float gt_area = gt_boxes_ptr[i * 4 + 2] * gt_boxes_ptr[i * 4 + 3];
    float max_overlap = 0.0f;
    int32_t max_overlap_anchor_idx = -1;
    for (int32_t j = 0; j < anchor_boxes_size_num; j++) {
      const float box_left =
          0 - 0.5f * static_cast<T>(anchor_boxes_size_ptr[2 * j]) / static_cast<T>(image_width);
      const float box_right =
          0 + 0.5f * static_cast<T>(anchor_boxes_size_ptr[2 * j]) / static_cast<T>(image_width);
      const float box_bottom =
          0
          + 0.5f * static_cast<T>(anchor_boxes_size_ptr[2 * j + 1]) / static_cast<T>(image_height);
      const float box_top =
          0
          - 0.5f * static_cast<T>(anchor_boxes_size_ptr[2 * j + 1]) / static_cast<T>(image_height);
      const float box_area =
          static_cast<T>(anchor_boxes_size_ptr[2 * j]) / static_cast<T>(image_width)
          * static_cast<T>(anchor_boxes_size_ptr[2 * j + 1]) / static_cast<T>(image_height);
      const float iw = min(box_right, gt_right) - max(gt_left, box_left);
      const float ih = min(box_bottom, gt_bottom) - max(box_top, gt_top);
      const float inter = iw * ih;
      float overlap = 0.0f;
      if (iw < 0 || ih < 0) {
        overlap = 0;
      } else {
        overlap = inter / (gt_area + box_area - inter);
      }
      if (overlap > max_overlap) {
        max_overlap = overlap;
        max_overlap_anchor_idx = j;
      }
    }
    for (int32_t j = 0; j < box_mask_num; j++) {
      if (box_mask_ptr[j] == max_overlap_anchor_idx) {
        const int32_t fm_i = static_cast<int32_t>(floor(gt_boxes_ptr[i * 4] * layer_width));
        const int32_t fm_j = static_cast<int32_t>(floor(gt_boxes_ptr[i * 4 + 1] * layer_height));
        const int32_t box_index = fm_j * layer_width * layer_nbox + fm_i * layer_nbox + j;
        max_overlaps_gt_indices[box_index] = i;
      }
    }
  }
}

__global__ void SelectSamples(const int32_t* max_overlaps_gt_indices_ptr, int32_t* pos_inds_ptr,
                              int32_t* neg_inds_ptr, int32_t* valid_num_ptr,
                              const int32_t box_num) {
  int32_t pos = 0;
  int32_t neg = 0;
  FOR_RANGE(int32_t, j, 0, box_num) {
    if (max_overlaps_gt_indices_ptr[j] >= 0) {
      pos_inds_ptr[pos++] = j;
    } else if (max_overlaps_gt_indices_ptr[j] == -1) {
      neg_inds_ptr[neg++] = j;
    }
  }
  // valid num
  valid_num_ptr[0] = pos;
  valid_num_ptr[1] = neg;
}

template<typename T>
__global__ void CalcBboxLoss(const int32_t box_num, const T* bbox_ptr, const T* gt_boxes_ptr,
                             const int32_t* gt_labels_ptr, const int32_t* pos_inds_ptr,
                             const int32_t* valid_num_ptr, const int32_t* max_overlaps_gt_indices,
                             const int32_t* anchor_boxes_size_ptr, const int32_t* box_mask_ptr,
                             T* bbox_loc_diff_ptr, int32_t* labels_ptr, const int32_t layer_nbox,
                             const int32_t layer_height, const int32_t layer_width,
                             const int32_t image_height, const int32_t image_width) {
  const int32_t pos_num = valid_num_ptr[0];
  CUDA_1D_KERNEL_LOOP(i, pos_num) {
    int box_index = pos_inds_ptr[i];
    int gt_index = max_overlaps_gt_indices[box_index];
    labels_ptr[box_index] = gt_labels_ptr[gt_index];
    const float scale = 2 - gt_boxes_ptr[gt_index * 4 + 2] * gt_boxes_ptr[gt_index * 4 + 3];

    const int32_t iw = (box_index / layer_nbox) % layer_width;
    const int32_t ih = (box_index / layer_nbox) / layer_width;
    const int32_t ibox = box_mask_ptr[box_index % layer_nbox];
    float gt_x = gt_boxes_ptr[gt_index * 4] * layer_width - iw;
    float gt_y = gt_boxes_ptr[gt_index * 4 + 1] * layer_height - ih;
    float gt_w = log(gt_boxes_ptr[gt_index * 4 + 2] * image_width
                     / static_cast<T>(anchor_boxes_size_ptr[ibox * 2]));
    float gt_h = log(gt_boxes_ptr[gt_index * 4 + 3] * image_height
                     / static_cast<T>(anchor_boxes_size_ptr[ibox * 2 + 1]));
    bbox_loc_diff_ptr[box_index * 4 + 0] = scale * (bbox_ptr[box_index * 4] - gt_x);
    bbox_loc_diff_ptr[box_index * 4 + 1] = scale * (bbox_ptr[box_index * 4 + 1] - gt_y);
    bbox_loc_diff_ptr[box_index * 4 + 2] = scale * (bbox_ptr[box_index * 4 + 2] - gt_w);
    bbox_loc_diff_ptr[box_index * 4 + 3] = scale * (bbox_ptr[box_index * 4 + 3] - gt_h);
  }
}

}  // namespace

template<typename T>
void YoloBoxDiffKernel<DeviceType::kGPU, T>::ForwardDataContent(
    const KernelCtx& ctx, std::function<Blob*(const std::string&)> BnInOp2Blob) const {
  Memset<DeviceType::kGPU>(ctx.device_ctx, BnInOp2Blob("bbox_loc_diff")->mut_dptr<T>(), 0,
                           BnInOp2Blob("bbox_loc_diff")->shape().elem_cnt() * sizeof(T));

  const YoloBoxDiffOpConf& conf = op_conf().yolo_box_diff_conf();

  const Blob* bbox_blob = BnInOp2Blob("bbox");
  const Blob* gt_boxes_blob = BnInOp2Blob("gt_boxes");
  int32_t* anchor_boxes_size_ptr = BnInOp2Blob("anchor_boxes_size_tmp")->mut_dptr<int32_t>();
  int32_t* box_mask_ptr = BnInOp2Blob("box_mask_tmp")->mut_dptr<int32_t>();

  const int32_t gt_max_num = gt_boxes_blob->shape().At(1);
  const int32_t box_num = bbox_blob->shape().At(1);
  const int32_t layer_height = conf.layer_height();
  const int32_t layer_width = conf.layer_width();
  const int32_t layer_nbox = conf.box_mask_size();
  const int32_t anchor_boxes_size_num = conf.anchor_boxes_size_size();

  FOR_RANGE(int32_t, i, 0, layer_nbox) {
    // box_mask_ptr[i] = conf.box_mask(i);
    KernelUtil<DeviceType::kGPU, int32_t>::Set(ctx.device_ctx, conf.box_mask(i), box_mask_ptr + i);
  }

  FOR_RANGE(int32_t, i, 0, anchor_boxes_size_num) {
    KernelUtil<DeviceType::kGPU, int32_t>::Set(ctx.device_ctx, conf.anchor_boxes_size(i).width(),
                                               anchor_boxes_size_ptr + 2 * i);
    KernelUtil<DeviceType::kGPU, int32_t>::Set(ctx.device_ctx, conf.anchor_boxes_size(i).height(),
                                               anchor_boxes_size_ptr + 2 * i + 1);
    // anchor_boxes_size_ptr[2 * i] = conf.anchor_boxes_size(i).width();
    // anchor_boxes_size_ptr[2 * i + 1] = conf.anchor_boxes_size(i).height();
  }
  // TODO()

  FOR_RANGE(int32_t, im_index, 0, bbox_blob->shape().At(0)) {
    const size_t gt_valid_num = gt_boxes_blob->dim1_valid_num(im_index);
    const T* gt_boxes_ptr = gt_boxes_blob->dptr<T>(im_index);
    CoordinateTransformGpu<<<BlocksNum4ThreadsNum(box_num), kCudaThreadsNumPerBlock, 0,
                             ctx.device_ctx->cuda_stream()>>>(
        box_num, bbox_blob->dptr<T>(im_index), anchor_boxes_size_ptr, box_mask_ptr,
        BnInOp2Blob("pred_bbox")->mut_dptr<T>(), conf.layer_height(), conf.layer_width(),
        conf.image_height(), conf.image_width(), layer_nbox);
    // CudaCheck(cudaStreamSynchronize(ctx.device_ctx->cuda_stream()));
    //    FOR_RANGE(int32_t, i, 0, gt_valid_num) {
    //      const float gt_left = gt_boxes_ptr[i * 4] - 0.5f * gt_boxes_ptr[i * 4 + 2];
    //      const float gt_right = gt_boxes_ptr[i * 4] + 0.5f * gt_boxes_ptr[i * 4 + 2];
    //      const float gt_bottom = gt_boxes_ptr[i * 4 + 1] - 0.5f * gt_boxes_ptr[i * 4 + 3];
    //      const float gt_top = gt_boxes_ptr[i * 4 + 1] + 0.5f * gt_boxes_ptr[i * 4 + 3];
    //      const float gt_area = gt_boxes_ptr[i * 4 + 2] * gt_boxes_ptr[i * 4 + 3];
    //      CalcIouGpu<<<BlocksNum4ThreadsNum(box_num), kCudaThreadsNumPerBlock, 0,
    //                   ctx.device_ctx->cuda_stream()>>>(
    //          box_num, BnInOp2Blob("pred_bbox")->dptr<T>(),
    //          BnInOp2Blob("overlaps")->mut_dptr<float>(), gt_max_num, i, gt_left, gt_right,
    //          gt_bottom, gt_top, gt_area);
    //    }
    CalcIouGpu<<<BlocksNum4ThreadsNum(box_num * gt_valid_num), kCudaThreadsNumPerBlock, 0,
                 ctx.device_ctx->cuda_stream()>>>(
        box_num, BnInOp2Blob("pred_bbox")->dptr<T>(), gt_boxes_ptr,
        BnInOp2Blob("overlaps")->mut_dptr<float>(), gt_max_num, gt_valid_num);
    // CudaCheck(cudaStreamSynchronize(ctx.device_ctx->cuda_stream()));
    SetMaxOverlapsAndGtIndex<<<BlocksNum4ThreadsNum(box_num), kCudaThreadsNumPerBlock, 0,
                               ctx.device_ctx->cuda_stream()>>>(
        box_num, gt_valid_num, gt_max_num, BnInOp2Blob("overlaps")->dptr<float>(),
        BnInOp2Blob("max_overlaps")->mut_dptr<float>(),
        BnInOp2Blob("max_overlaps_gt_indices")->mut_dptr<int32_t>(), conf.ignore_thresh(),
        conf.truth_thresh());
    // CudaCheck(cudaStreamSynchronize(ctx.device_ctx->cuda_stream()));
    CalcGtNearestAnchorSize<<<BlocksNum4ThreadsNum(gt_valid_num), kCudaThreadsNumPerBlock, 0,
                              ctx.device_ctx->cuda_stream()>>>(
        gt_valid_num, gt_boxes_ptr, anchor_boxes_size_ptr, box_mask_ptr,
        BnInOp2Blob("max_overlaps_gt_indices")->mut_dptr<int32_t>(), anchor_boxes_size_num,
        layer_nbox, conf.layer_height(), conf.layer_width(), layer_nbox, conf.image_height(),
        conf.image_width());
    // CudaCheck(cudaStreamSynchronize(ctx.device_ctx->cuda_stream()));
    int32_t* pos_inds_ptr = BnInOp2Blob("pos_inds")->mut_dptr<int32_t>(im_index);
    SelectSamples<<<1, 1, 0, ctx.device_ctx->cuda_stream()>>>(
        BnInOp2Blob("max_overlaps_gt_indices")->dptr<int32_t>(), pos_inds_ptr,
        BnInOp2Blob("neg_inds")->mut_dptr<int32_t>(im_index),
        BnInOp2Blob("valid_num")->mut_dptr<int32_t>(im_index), box_num);
    // BnInOp2Blob("pos_inds")->set_dim1_valid_num(im_index, pos);
    // BnInOp2Blob("neg_inds")->set_dim1_valid_num(im_index, neg);
    // CudaCheck(cudaStreamSynchronize(ctx.device_ctx->cuda_stream()));
    CalcBboxLoss<<<BlocksNum4ThreadsNum(gt_valid_num), kCudaThreadsNumPerBlock, 0,
                   ctx.device_ctx->cuda_stream()>>>(
        box_num, bbox_blob->dptr<T>(im_index), gt_boxes_ptr,
        BnInOp2Blob("gt_labels")->dptr<int32_t>(im_index), pos_inds_ptr,
        BnInOp2Blob("valid_num")->dptr<int32_t>(im_index),
        BnInOp2Blob("max_overlaps_gt_indices")->dptr<int32_t>(), anchor_boxes_size_ptr,
        box_mask_ptr, BnInOp2Blob("bbox_loc_diff")->mut_dptr<T>(im_index),
        BnInOp2Blob("pos_cls_label")->mut_dptr<int32_t>(im_index), layer_nbox, conf.layer_height(),
        conf.layer_width(), conf.image_height(), conf.image_width());
  }

  
  std::vector<int32_t> cpu_valid_num;
  cpu_valid_num.resize(bbox_blob->shape().At(0) * 2);
  CudaCheck(cudaMemcpyAsync(cpu_valid_num.data(), BnInOp2Blob("valid_num")->dptr(),
                            BnInOp2Blob("valid_num")->ByteSizeOfDataContentField(),
                            cudaMemcpyDeviceToHost, ctx.device_ctx->cuda_stream()));
  CudaCheck(cudaStreamSynchronize(ctx.device_ctx->cuda_stream()));
  FOR_RANGE(size_t, i, 0, bbox_blob->shape().At(0)) {
    BnInOp2Blob("pos_inds")->set_dim1_valid_num(i, cpu_valid_num[2 * i]);
    BnInOp2Blob("neg_inds")->set_dim1_valid_num(i, cpu_valid_num[2 * i + 1]);
  }
}

template<typename T>
void YoloBoxDiffKernel<DeviceType::kGPU, T>::BackwardDataContent(
    const KernelCtx& ctx, std::function<Blob*(const std::string&)> BnInOp2Blob) const {
  const Blob* bbox_loc_diff_diff_blob = BnInOp2Blob(GenDiffBn("bbox_loc_diff"));
  Blob* bbox_diff_blob = BnInOp2Blob(GenDiffBn("bbox"));

  KernelUtil<DeviceType::kGPU, T>::Mul(
      ctx.device_ctx, bbox_diff_blob->shape().elem_cnt(), bbox_loc_diff_diff_blob->dptr<T>(),
      BnInOp2Blob("bbox_loc_diff")->dptr<T>(), bbox_diff_blob->mut_dptr<T>());
}

template<typename T>
void YoloBoxDiffKernel<DeviceType::kGPU, T>::ForwardDim1ValidNum(
    const KernelCtx& ctx, std::function<Blob*(const std::string&)> BnInOp2Blob) const {}

#define INSTANTIATE_GPU_YOLO_BOX_DIFF_KERNEL(type_cpp, type_proto) \
  template struct YoloBoxDiffKernel<DeviceType::kGPU, type_cpp>;
OF_PP_FOR_EACH_TUPLE(INSTANTIATE_GPU_YOLO_BOX_DIFF_KERNEL, FLOATING_DATA_TYPE_SEQ);

}  // namespace oneflow
