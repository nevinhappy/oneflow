#include "oneflow/core/common/flat_msg_view.h"
#include "oneflow/core/vm/stream_type.h"
#include "oneflow/core/vm/instruction_type.h"
#include "oneflow/core/vm/instruction.msg.h"
#include "oneflow/core/vm/copy_instruction.msg.h"
#include "oneflow/core/vm/stream.msg.h"
#include "oneflow/core/vm/thread_ctx.msg.h"
#include "oneflow/core/vm/cuda_instruction_status_querier.h"
#include "oneflow/core/vm/cuda_stream_handle_device_context.h"
#include "oneflow/core/vm/mem_buffer_object.h"
#include "oneflow/core/device/cuda_util.h"
#include "oneflow/core/common/util.h"
#include "oneflow/core/kernel/kernel_util.h"
#include "oneflow/core/job/resource.pb.h"

namespace oneflow {
namespace vm {

class CudaCopyD2HStreamType final : public StreamType {
 public:
  CudaCopyD2HStreamType() = default;
  ~CudaCopyD2HStreamType() = default;

  const char* device_tag() const override { return "gpu"; }

  void InitDeviceCtx(std::unique_ptr<DeviceCtx>* device_ctx, Stream* stream) const override;

  void InitInstructionStatus(const Stream& stream,
                             InstructionStatusBuffer* status_buffer) const override;
  void DeleteInstructionStatus(const Stream& stream,
                               InstructionStatusBuffer* status_buffer) const override;
  bool QueryInstructionStatusDone(const Stream& stream,
                                  const InstructionStatusBuffer& status_buffer) const override;
  void Compute(Instruction* instruction) const override;
  ObjectMsgPtr<StreamDesc> MakeWorkerStreamDesc(const Resource& resource,
                                                int64_t this_machine_id) const override;
};

namespace {

class CudaCopyD2HInstructionType final : public InstructionType {
 public:
  CudaCopyD2HInstructionType() = default;
  ~CudaCopyD2HInstructionType() override = default;

  using stream_type = CudaCopyD2HStreamType;

  void Infer(Instruction* instruction) const override { /* do nothing */
  }
  void Compute(Instruction* instruction) const override {
    void* dst = nullptr;
    const void* src = nullptr;
    size_t size = 0;
    const auto& stream = instruction->stream();
    {
      FlatMsgView<CopyInstruction> view;
      CHECK(view.Match(instruction->instr_msg().operand()));
      size = view->size();
      const auto& dst_buffer_type =
          instruction->operand_type(view->dst()).Get<MemBufferObjectType>();
      CHECK_LE(size, dst_buffer_type.size());
      CHECK(dst_buffer_type.mem_case().has_host_mem());
      CHECK(dst_buffer_type.mem_case().host_mem().has_cuda_pinned_mem());
      auto* dst_buffer_value =
          instruction->mut_operand_value(view->dst())->Mut<MemBufferObjectValue>();
      dst = dst_buffer_value->mut_data();

      const auto& src_buffer_type =
          instruction->operand_type(view->src()).Get<MemBufferObjectType>();
      CHECK_LE(size, src_buffer_type.size());
      CHECK(src_buffer_type.mem_case().has_device_cuda_mem());
      CHECK_EQ(src_buffer_type.mem_case().device_cuda_mem().device_id(), stream.device_id());
      const auto& src_buffer_value =
          instruction->operand_value(view->src()).Get<MemBufferObjectValue>();
      src = src_buffer_value.data();
    }
    Memcpy<DeviceType::kGPU>(stream.device_ctx().get(), dst, src, size,
                             cudaMemcpyKind::cudaMemcpyDeviceToHost);
  }
};
COMMAND(RegisterInstructionType<CudaCopyD2HInstructionType>("CopyD2H"));
COMMAND(RegisterInstructionType<CudaCopyD2HInstructionType>("CudaCopyD2H"));

}  // namespace

void CudaCopyD2HStreamType::InitDeviceCtx(std::unique_ptr<DeviceCtx>* device_ctx,
                                          Stream* stream) const {
  device_ctx->reset(
      new CudaStreamHandleDeviceCtx(stream->mut_callback_list(), stream->device_id()));
}

void CudaCopyD2HStreamType::InitInstructionStatus(const Stream& stream,
                                                  InstructionStatusBuffer* status_buffer) const {
  static_assert(sizeof(CudaInstrStatusQuerier) < kInstructionStatusBufferBytes, "");
  CudaInstrStatusQuerier::PlacementNew(status_buffer->mut_buffer()->mut_data(), stream.device_id());
}

void CudaCopyD2HStreamType::DeleteInstructionStatus(const Stream& stream,
                                                    InstructionStatusBuffer* status_buffer) const {
  // do nothing
}

bool CudaCopyD2HStreamType::QueryInstructionStatusDone(
    const Stream& stream, const InstructionStatusBuffer& status_buffer) const {
  return CudaInstrStatusQuerier::Cast(status_buffer.buffer().data())->done();
}

void CudaCopyD2HStreamType::Compute(Instruction* instruction) const {
  auto* stream = instruction->mut_stream();
  cudaSetDevice(stream->device_id());
  {
    const auto& instr_type_id = instruction->mut_instr_msg()->instr_type_id();
    CHECK_EQ(instr_type_id.stream_type_id().interpret_type(), InterpretType::kCompute);
    instr_type_id.instruction_type().Compute(instruction);
  }
  stream->mut_callback_list()->MoveTo(instruction->mut_callback_list());
  char* data_ptr = instruction->mut_status_buffer()->mut_buffer()->mut_data();
  CudaInstrStatusQuerier::MutCast(data_ptr)->SetLaunched(stream->device_ctx().get());
}

ObjectMsgPtr<StreamDesc> CudaCopyD2HStreamType::MakeWorkerStreamDesc(
    const Resource& resource, int64_t this_machine_id) const {
  std::size_t device_num = resource.gpu_device_num();
  auto ret = ObjectMsgPtr<StreamDesc>::New();
  ret->mutable_stream_type_id()->__Init__(LookupStreamType4TypeIndex<CudaCopyD2HStreamType>());
  ret->set_num_machines(1);
  ret->set_num_streams_per_machine(device_num);
  ret->set_num_streams_per_thread(1);
  ret->set_start_global_device_id(this_machine_id * device_num);
  return ret;
}

}  // namespace vm
}  // namespace oneflow
