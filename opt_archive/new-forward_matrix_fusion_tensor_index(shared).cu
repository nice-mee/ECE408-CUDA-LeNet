#include <cmath>
#include <iostream>
#include "gpu-new-forward.h"
#include <cuda_fp16.h>
#include <mma.h>
using namespace nvcuda;

#define TILE_WIDTH 16

half *device_input_fp16;
half *device_mask_fp16;
half *device_output_fp16;

__global__ void fp32_to_fp16(half *dst, const float *src, int n)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) {
        dst[i] = __float2half(src[i]);
    }
}

__global__ void fp16_to_fp32(float *dst, const half *src, int n)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) {
        dst[i] = __half2float(src[i]);
    }
}

__global__ void mat_forward_kernel_tensor(half *output, const half *input, const half *mask, const int B, const int M, const int C, const int H, const int W, const int K,const int S)
{
    #define out_4d(i3, i2, i1, i0) output[(i3) * (M * H_out * W_out) + (i2) * (H_out * W_out) + (i1) * (W_out) + i0]
    #define in_4d(i3, i2, i1, i0) input[(i3) * (C * H * W) + (i2) * (H * W) + (i1) * (W) + i0]
    #define mask_4d(i3, i2, i1, i0) mask[(i3) * (C * K * K) + (i2) * (K * K) + (i1) * (K) + i0]

    const int H_out = (H - K)/S + 1;
    const int W_out = (W - K)/S + 1;
    int b = blockIdx.z;
    int numAColumns = C*K*K;
    int numBColumns = H_out*W_out;

    __shared__ half tileA[16][16];
    __shared__ half tileB[16][16];
    __shared__ half tileC[16][16];
    __shared__ int c_arr[16];
    __shared__ int p_arr[16];
    __shared__ int q_arr[16];

    wmma::fragment<wmma::matrix_a, 16, 16, 16, half, wmma::row_major> a_frag;
    wmma::fragment<wmma::matrix_b, 16, 16, 16, half, wmma::row_major> b_frag;
    wmma::fragment<wmma::accumulator, 16, 16, 16, half> c_frag;
    wmma::fill_fragment(c_frag, 0.0);

    
    for (int i = 0; i < ceil(numAColumns/(float) 16); i++) {
        int RowB = i * 16 + threadIdx.x;
        c_arr[threadIdx.x] = RowB / (K*K);
        p_arr[threadIdx.x] = RowB % (K*K) / K;
        q_arr[threadIdx.x] = RowB % K;
        int ColB = blockIdx.x * 16 + threadIdx.x;
        int ColA = i * 16 + threadIdx.x;
        int h = ColB / W_out;
        int w = ColB % W_out;
        for (int j = 0; j < 8; j++) {
            int offset = threadIdx.y * 8 + j;
            int RowA = blockIdx.y * 16 + offset;
            if (RowA < M && ColA < numAColumns)
                tileA[offset][threadIdx.x] = mask[RowA * numAColumns + ColA];
            else
                tileA[offset][threadIdx.x] = 0.0;
            RowB = i * 16 + offset;
            if (ColB < numBColumns && RowB < numAColumns)
                tileB[offset][threadIdx.x] = in_4d(b, c_arr[offset], h * S + p_arr[offset], w * S + q_arr[offset]);
            else
                tileB[offset][threadIdx.x] = 0.0;
        }
        __syncthreads();

        wmma::load_matrix_sync(a_frag, (half *) tileA, 16);
        wmma::load_matrix_sync(b_frag, (half *) tileB, 16);
        wmma::mma_sync(c_frag, a_frag, b_frag, c_frag);
    }
    wmma::store_matrix_sync((half *) tileC, c_frag, 16, wmma::mem_row_major);
    for (int i = 0; i < 8; i++) {
        int RowC = blockIdx.y * 16 + threadIdx.y * 8 + i;
        int ColC = blockIdx.x * 16 + threadIdx.x;
        if (RowC < M && ColC < numBColumns)
            output[b * (M * numBColumns) + RowC * numBColumns + ColC] = tileC[threadIdx.y * 8 + i][threadIdx.x];
    }

    #undef out_4d
    #undef in_4d
    #undef mask_4d
}

	
__host__ void GPUInterface::conv_forward_gpu_prolog(const float *host_output, const float *host_input, const float *host_mask, float **device_output_ptr, float **device_input_ptr, float **device_mask_ptr, const int B, const int M, const int C, const int H, const int W, const int K, const int S)
{
    // Allocate memory and copy over the relevant data structures to the GPU

    // We pass double pointers for you to initialize the relevant device pointers,
    //  which are passed to the other two functions.

    // Useful snippet for error checking
    // cudaError_t error = cudaGetLastError();
    // if(error != cudaSuccess)
    // {
    //     std::cout<<"CUDA error: "<<cudaGetErrorString(error)<<std::endl;
    //     exit(-1);
    // }

    const int H_out = (H - K)/S + 1;
    const int W_out = (W - K)/S + 1;
    cudaMalloc((void **)device_input_ptr, B*C*H*W*sizeof(float));
    cudaMalloc((void **)device_output_ptr, B*M*H_out*W_out*sizeof(float));
    cudaMalloc((void **)device_mask_ptr, M*C*K*K*sizeof(float));
    cudaMalloc((void **)&device_input_fp16, B*C*H*W*sizeof(half));
    cudaMalloc((void **)&device_mask_fp16, M*C*K*K*sizeof(half));
    cudaMalloc((void **)&device_output_fp16, B*M*H_out*W_out*sizeof(half));


    cudaMemcpy(*device_input_ptr, host_input, B*C*H*W*sizeof(float), cudaMemcpyHostToDevice);
    cudaMemcpy(*device_mask_ptr, host_mask, M*C*K*K*sizeof(float), cudaMemcpyHostToDevice);
}


__host__ void GPUInterface::conv_forward_gpu(float *device_output, const float *device_input, const float *device_mask, const int B, const int M, const int C, const int H, const int W, const int K, const int S)
{
    // Set the kernel dimensions and call the kernel
    const int H_out = (H - K)/S + 1;
    const int W_out = (W - K)/S + 1;
    int W_size = ceil((float)W_out/TILE_WIDTH);
    int H_size = ceil((float)H_out/TILE_WIDTH);

    // std::cout << "B: " << B << " M: " << M << " C: " << C << " H: " << H << " W: " << W << " K: " << K << " S: " << S << std::endl;

    fp32_to_fp16<<<ceil((float)B*C*H*W/(float)256), 256>>>(device_input_fp16, device_input, B*C*H*W);
    fp32_to_fp16<<<ceil((float)M*C*K*K/(float)256), 256>>>(device_mask_fp16, device_mask, M*C*K*K);

    dim3 dimBlock = dim3(16, 2, 1);
    dim3 dimGrid = dim3(ceil((H_out*W_out)/(float)16), ceil(M/(float)16), B);
    mat_forward_kernel_tensor<<<dimGrid, dimBlock>>>(device_output_fp16, device_input_fp16, device_mask_fp16, B, M, C, H, W, K, S);

    fp16_to_fp32<<<ceil((float)B*M*H_out*W_out/(float)256), 256>>>(device_output, device_output_fp16, B*M*H_out*W_out);

    // cudaError_t error = cudaGetLastError();
    // if(error != cudaSuccess)
    // {
    //     std::cout<<"CUDA error: "<<cudaGetErrorString(error)<<std::endl;
    //     exit(-1);
    // }
}


__host__ void GPUInterface::conv_forward_gpu_epilog(float *host_output, float *device_output, float *device_input, float *device_mask, const int B, const int M, const int C, const int H, const int W, const int K, const int S)
{
    const int H_out = (H - K)/S + 1;
    const int W_out = (W - K)/S + 1;
    // Copy the output back to host
    cudaMemcpy(host_output, device_output, B*M*H_out*W_out*sizeof(float), cudaMemcpyDeviceToHost);
   
    // Free device memory
    cudaFree(device_output);
    cudaFree(device_input);
    cudaFree(device_mask);
    cudaFree(device_input_fp16);
    cudaFree(device_mask_fp16);
    cudaFree(device_output_fp16);
}


__host__ void GPUInterface::get_device_properties()
{
    int deviceCount;
    cudaGetDeviceCount(&deviceCount);

    for(int dev = 0; dev < deviceCount; dev++)
    {
        cudaDeviceProp deviceProp;
        cudaGetDeviceProperties(&deviceProp, dev);

        std::cout<<"Device "<<dev<<" name: "<<deviceProp.name<<std::endl;
        std::cout<<"Computational capabilities: "<<deviceProp.major<<"."<<deviceProp.minor<<std::endl;
        std::cout<<"Max Global memory size: "<<deviceProp.totalGlobalMem<<std::endl;
        std::cout<<"Max Constant memory size: "<<deviceProp.totalConstMem<<std::endl;
        std::cout<<"Max Shared memory size per block: "<<deviceProp.sharedMemPerBlock<<std::endl;
        std::cout<<"Max threads per block: "<<deviceProp.maxThreadsPerBlock<<std::endl;
        std::cout<<"Max block dimensions: "<<deviceProp.maxThreadsDim[0]<<" x, "<<deviceProp.maxThreadsDim[1]<<" y, "<<deviceProp.maxThreadsDim[2]<<" z"<<std::endl;
        std::cout<<"Max grid dimensions: "<<deviceProp.maxGridSize[0]<<" x, "<<deviceProp.maxGridSize[1]<<" y, "<<deviceProp.maxGridSize[2]<<" z"<<std::endl;
        std::cout<<"Warp Size: "<<deviceProp.warpSize<<std::endl;
    }
}
