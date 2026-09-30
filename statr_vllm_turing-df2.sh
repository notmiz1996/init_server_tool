#!/bin/bash
# ============================================================
# vLLM-Turing FP8 DFlash2 启动脚本
# 脚本用于启动项目https://github.com/javier-house/vllm-Turing的启动命令，已经经过过百小时测试。
# ============================================================

# ---------- 0. 停止并删除旧容器 ----------
docker rm -f vllm-turing-fp8 2>/dev/null

# ---------- 1.1 交互确认后清理宿主机缓存目录 ----------
CACHE_ROOT=/home/notmiz/AI/javier-house/vllm-Turing-cache/cache

# 如果 stdin 是终端，则交互询问；否则（管道/CI）默认跳过
if [ -t 0 ]; then
    read -r -p "是否清理宿主机缓存目录 (${CACHE_ROOT}) ？[y/N] " CLEAN_CACHE
else
    CLEAN_CACHE="${CLEAN_CACHE:-n}"
fi

case "$CLEAN_CACHE" in
    [yY]|[yY][eE][sS])
        echo ">>> 开始清理宿主机缓存目录..."
        sudo rm -rf "$CACHE_ROOT/fp8/vllm/"*
        sudo rm -rf "$CACHE_ROOT/shared/flashinfer/"*
        sudo rm -rf "$CACHE_ROOT/fp8/triton/"*
        sudo rm -rf "$CACHE_ROOT/shared/torch_extensions/"*
        echo ">>> 缓存清理完成。"
        ;;
    *)
        echo ">>> 跳过缓存清理，直接使用已有缓存。"
        ;;
esac

# ---------- 1.2 清理共享内存（同样改为交互确认，可按需保留）----------
if [ -t 0 ]; then
    read -r -p "是否清理共享内存 /dev/shm/vllm_* ？[y/N] " CLEAN_SHM
else
    CLEAN_SHM="${CLEAN_SHM:-n}"
fi

case "$CLEAN_SHM" in
    [yY]|[yY][eE][sS])
        echo ">>> 清理共享内存..."
        sudo rm -rf /dev/shm/vllm_*
        echo ">>> 共享内存清理完成。"
        ;;
    *)
        echo ">>> 跳过共享内存清理。"
        ;;
esac

# ---------- 2. 环境变量 ----------
cd /home/notmiz/AI/javier-house/vllm-Turing

export VLLM_API_KEY='dcn4059238.'
export VLLM_SM75_CACHE_ROOT=/home/notmiz/AI/javier-house/vllm-Turing-cache/cache
export VLLM_SM75_MODEL_CACHE_ROOT=/home/notmiz/AI/model-cache

# ---------- 3. 启动容器 ----------
docker run -d --name vllm-turing-fp8 --gpus all --shm-size 16g \
  --ulimit nofile=1048576:1048576 \
  -p 8000:8000 \
  -v /home/notmiz/AI/javier-house/vllm-Turing:/vllm-Turing \
  -v "$VLLM_SM75_MODEL_CACHE_ROOT":/root/.cache/modelscope \
  -v "$VLLM_SM75_MODEL_CACHE_ROOT":/root/.cache/huggingface \
  -v "$VLLM_SM75_CACHE_ROOT/fp8/vllm":/root/.cache/vllm \
  -v "$VLLM_SM75_CACHE_ROOT/shared/flashinfer":/root/.cache/flashinfer \
  -v "$VLLM_SM75_CACHE_ROOT/fp8/triton":/root/.triton/cache \
  -v "$VLLM_SM75_CACHE_ROOT/shared/torch_extensions":/root/.cache/torch_extensions \
  -v /home/notmiz/AI/model-cache/hub/models/Qwen3.8-27B-DFlash2:/models/Qwen3.8-27B-DFlash2 \
  -e VLLM_FIREFLY=1 -e VLLM_FIREFLY_AR=auto \
  -e VLLM_TURING_UPDATE=0 \
  -e TRITON_CACHE_DIR=/root/.triton/cache \
  -e TORCH_EXTENSIONS_DIR=/root/.cache/torch_extensions \
  -e VLLM_USE_MODELSCOPE=true \
  -e MODELSCOPE_CACHE=/root/.cache/modelscope/hub \
  -e VLLM_GDN_DECODE_KERNEL=triton \
  -e VLLM_MARLIN_USE_ATOMIC_ADD=1 \
  -e VLLM_USE_FLASHINFER_SAMPLER=0 \
  -e VLLM_ALLOW_LONG_MAX_MODEL_LEN=1 \
  -e VLLM_USE_NCCL_SYMM_MEM=0 \
  -e VLLM_ALLREDUCE_USE_SYMM_MEM=0 \
  -e VLLM_ENABLE_CUDA_COMPATIBILITY=0 \
  -e OMP_NUM_THREADS=2 \
  -e VLLM_ENGINE_READY_TIMEOUT_S=1800 \
  -e VLLM_ENGINE_ITERATION_TIMEOUT_S=1800 \
  -e VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS=1800 \
  vllm-turing \
  Qwen/Qwen3.8-27B-FP8 \
  --served-model-name VLLM-Qwen3.8-27B \
  --host 0.0.0.0 --port 8000 --api-key "$VLLM_API_KEY" \
  --tensor-parallel-size 4 --disable-custom-all-reduce \
  --max-num-seqs 4 --max-num-batched-tokens 8192 \
  --gpu-memory-utilization 0.92 --max-model-len 262144 \
  --attention-config '{"backend":"FLASHINFER"}' \
  --gdn-prefill-backend flashqla_sm75 \
  --kv-cache-dtype fp8_e4m3 --block-size 32 --dtype float16 \
  --hf-overrides '{"dtype":"float16"}' --generation-config vllm \
  --enable-prefix-caching --async-scheduling \
  --enable-prompt-tokens-details \
  --no-disable-hybrid-kv-cache-manager \
  --mamba-cache-mode align \
  --mm-encoder-attn-backend TORCH_SDPA \
  --reasoning-parser qwen3 \
  --compilation-config '{"cudagraph_mode":"FULL_AND_PIECEWISE","cudagraph_capture_sizes":[8]}' \
  --kv-cache-memory-bytes 3288334336 \
  --kv-transfer-config '{"kv_connector":"OffloadingConnector","kv_role":"kv_both","kv_connector_extra_config":{"spec_name":"CPUOffloadingSpec","cpu_bytes_to_use":8589934592}}' \
  --speculative-config '{"method":"dflash","model":"/models/Qwen3.8-27B-DFlash2","num_speculative_tokens":7,"draft_tensor_parallel_size":4,"max_model_len":262144,"kv_cache_dtype":"auto","attention_backend":"FLASHINFER","draft_sample_method":"probabilistic"}' \
  --scheduler-cls vllm.v1.core.sched.scheduler_sm75.SM75Scheduler \
  --tool-call-parser qwen3_coder --enable-auto-tool-choice \
  --auto-sleep-idle-timeout 30 --auto-sleep-offload-target exit

# ---------- 4. 查看日志 ----------
docker logs -f vllm-turing-fp8