/*
 * Copyright (c) 2017, NVIDIA CORPORATION. All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */

#include "cudaYUV.h"
#include "cudaVector.h"

#define COLOR_COMPONENT_MASK            0x3FF
#define COLOR_COMPONENT_BIT_SIZE        10

#define FIXED_DECIMAL_POINT             24
#define FIXED_POINT_MULTIPLIER          1.0f
#define FIXED_COLOR_COMPONENT_MASK      0xffffffff


static inline __device__ float clamp( float x )	{ return fminf(fmaxf(x, 0.0f), 255.0f); }

// YUV2RGB
template<typename T>
static inline __device__ T YUV2RGB(const uint3& yuvi)
{
	const float luma = float(yuvi.x);
	const float u    = float(yuvi.y) - 512.0f;
	const float v    = float(yuvi.z) - 512.0f;
	const float s    = 1.0f / 1024.0f * 255.0f;	// TODO clamp for uchar output?

	// R = Y + 1.140V
   	// G = Y - 0.395U - 0.581V
   	// B = Y + 2.032U
	return make_vec<T>(clamp((luma + 1.140f * v) * s),
				    clamp((luma - 0.395f * u - 0.581f * v) * s),
				    clamp((luma + 2.032f * u) * s), 255);
}


__device__ uint32_t RGBAPACK_8bit(float red, float green, float blue, uint32_t alpha)
{
    uint32_t ARGBpixel = 0;

    // Clamp final 10 bit results
    red   = min(max(red,   0.0f), 255.0f);
    green = min(max(green, 0.0f), 255.0f);
    blue  = min(max(blue,  0.0f), 255.0f);

    // Convert to 8 bit unsigned integers per color component
    ARGBpixel = ((((uint32_t)red)   << 24) |
                 (((uint32_t)green) << 16) |
		       (((uint32_t)blue)  <<  8) | (uint32_t)alpha);

    return  ARGBpixel;
}


__device__ uint32_t RGBAPACK_10bit(float red, float green, float blue, uint32_t alpha)
{
    uint32_t ARGBpixel = 0;

    // Clamp final 10 bit results
    red   = min(max(red,   0.0f), 1023.f);
    green = min(max(green, 0.0f), 1023.f);
    blue  = min(max(blue,  0.0f), 1023.f);

    // Convert to 8 bit unsigned integers per color component
    ARGBpixel = ((((uint32_t)red   >> 2) << 24) |
                 (((uint32_t)green >> 2) << 16) |
                 (((uint32_t)blue  >> 2) <<  8) | (uint32_t)alpha);

    return  ARGBpixel;
}


__global__ void Passthru(uint32_t *srcImage,   size_t nSourcePitch,
                         uint32_t *dstImage,   size_t nDestPitch,
                         uint32_t width,       uint32_t height)
{
    int x, y;
    uint32_t yuv101010Pel[2];
    uint32_t processingPitch = ((width) + 63) & ~63;
    uint32_t dstImagePitch   = nDestPitch >> 2;
    uint8_t *srcImageU8     = (uint8_t *)srcImage;

    processingPitch = nSourcePitch;

    // Pad borders with duplicate pixels, and we multiply by 2 because we process 2 pixels per thread
    x = blockIdx.x * (blockDim.x << 1) + (threadIdx.x << 1);
    y = blockIdx.y *  blockDim.y       +  threadIdx.y;

    if (x >= width)
        return; //x = width - 1;

    if (y >= height)
        return; // y = height - 1;

    // Read 2 Luma components at a time, so we don't waste processing since CbCr are decimated this way.
    // if we move to texture we could read 4 luminance values
    yuv101010Pel[0] = (srcImageU8[y * processingPitch + x    ]);
    yuv101010Pel[1] = (srcImageU8[y * processingPitch + x + 1]);

    // this steps performs the color conversion
    float luma[2];

    luma[0]   = (yuv101010Pel[0]        & 0x00FF);
    luma[1]   = (yuv101010Pel[1]        & 0x00FF);

    // Clamp the results to RGBA
    dstImage[y * dstImagePitch + x     ] = RGBAPACK_8bit(luma[0], luma[0], luma[0], 255);	 // alpha=((uint32_t)0xff<< 24);
    dstImage[y * dstImagePitch + x + 1 ] = RGBAPACK_8bit(luma[1], luma[1], luma[1], 255);
}


// NV12ToRGBA
template<typename T>
__global__ void NV12ToRGBA(uint32_t* srcImage, size_t nSourcePitch,
                           T* dstImage,        size_t nDestPitch,
                           uint32_t width,     uint32_t height)
{
	int x, y;
	uint32_t yuv101010Pel[2];
	uint32_t processingPitch = ((width) + 63) & ~63;
	uint8_t *srcImageU8     = (uint8_t *)srcImage;

	processingPitch = nSourcePitch;

	// Pad borders with duplicate pixels, and we multiply by 2 because we process 2 pixels per thread
	x = blockIdx.x * (blockDim.x << 1) + (threadIdx.x << 1);
	y = blockIdx.y *  blockDim.y       +  threadIdx.y;

	if( x >= width )
		return; //x = width - 1;

	if( y >= height )
		return; // y = height - 1;

	// Read 2 Luma components at a time, so we don't waste processing since CbCr are decimated this way.
	// if we move to texture we could read 4 luminance values
	yuv101010Pel[0] = (srcImageU8[y * processingPitch + x    ]) << 2;
	yuv101010Pel[1] = (srcImageU8[y * processingPitch + x + 1]) << 2;

	uint32_t chromaOffset    = processingPitch * height;
	int y_chroma = y >> 1;

	if (y & 1)  // odd scanline ?
	{
		uint32_t chromaCb;
		uint32_t chromaCr;

		chromaCb = srcImageU8[chromaOffset + y_chroma * processingPitch + x    ];
		chromaCr = srcImageU8[chromaOffset + y_chroma * processingPitch + x + 1];

		if (y_chroma < ((height >> 1) - 1)) // interpolate chroma vertically
		{
			chromaCb = (chromaCb + srcImageU8[chromaOffset + (y_chroma + 1) * processingPitch + x    ] + 1) >> 1;
			chromaCr = (chromaCr + srcImageU8[chromaOffset + (y_chroma + 1) * processingPitch + x + 1] + 1) >> 1;
		}

		yuv101010Pel[0] |= (chromaCb << (COLOR_COMPONENT_BIT_SIZE       + 2));
		yuv101010Pel[0] |= (chromaCr << ((COLOR_COMPONENT_BIT_SIZE << 1) + 2));

		yuv101010Pel[1] |= (chromaCb << (COLOR_COMPONENT_BIT_SIZE       + 2));
		yuv101010Pel[1] |= (chromaCr << ((COLOR_COMPONENT_BIT_SIZE << 1) + 2));
	}
	else
	{
		yuv101010Pel[0] |= ((uint32_t)srcImageU8[chromaOffset + y_chroma * processingPitch + x    ] << (COLOR_COMPONENT_BIT_SIZE       + 2));
		yuv101010Pel[0] |= ((uint32_t)srcImageU8[chromaOffset + y_chroma * processingPitch + x + 1] << ((COLOR_COMPONENT_BIT_SIZE << 1) + 2));

		yuv101010Pel[1] |= ((uint32_t)srcImageU8[chromaOffset + y_chroma * processingPitch + x    ] << (COLOR_COMPONENT_BIT_SIZE       + 2));
		yuv101010Pel[1] |= ((uint32_t)srcImageU8[chromaOffset + y_chroma * processingPitch + x + 1] << ((COLOR_COMPONENT_BIT_SIZE << 1) + 2));
	}

	// this steps performs the color conversion
	const uint3 yuvi_0 = make_uint3((yuv101010Pel[0] &   COLOR_COMPONENT_MASK),
	                               ((yuv101010Pel[0] >>  COLOR_COMPONENT_BIT_SIZE)       & COLOR_COMPONENT_MASK),
					               ((yuv101010Pel[0] >> (COLOR_COMPONENT_BIT_SIZE << 1)) & COLOR_COMPONENT_MASK));
  
	const uint3 yuvi_1 = make_uint3((yuv101010Pel[1] &   COLOR_COMPONENT_MASK),
							       ((yuv101010Pel[1] >>  COLOR_COMPONENT_BIT_SIZE)       & COLOR_COMPONENT_MASK),
								   ((yuv101010Pel[1] >> (COLOR_COMPONENT_BIT_SIZE << 1)) & COLOR_COMPONENT_MASK));
								   
	// YUV to RGB transformation conversion
	dstImage[y * width + x]     = YUV2RGB<T>(yuvi_0);
	dstImage[y * width + x + 1] = YUV2RGB<T>(yuvi_1);
}


template<typename T> 
cudaError_t launchNV12ToRGBA( void* srcDev, size_t srcPitch, T* destDev, size_t destPitch, size_t width, size_t height )
{
	if( !srcDev || !destDev )
		return cudaErrorInvalidDevicePointer;

	if( srcPitch == 0 || destPitch == 0 || width == 0 || height == 0 )
		return cudaErrorInvalidValue;

	const dim3 blockDim(32,8,1);
	const dim3 gridDim(iDivUp(width,blockDim.x), iDivUp(height, blockDim.y), 1);

	NV12ToRGBA<T><<<gridDim, blockDim>>>( (uint32_t*)srcDev, srcPitch, destDev, destPitch, width, height );
	
	return CUDA(cudaGetLastError());
}


// cudaNV12ToRGB (uchar3)
cudaError_t cudaNV12ToRGB( void* srcDev, size_t srcPitch, uchar3* destDev, size_t destPitch, size_t width, size_t height )
{
	return launchNV12ToRGBA<uchar3>(srcDev, srcPitch, destDev, destPitch, width, height);
}

// cudaNV12ToRGB (uchar3)
cudaError_t cudaNV12ToRGB( void* srcDev, uchar3* destDev, size_t width, size_t height )
{
	return cudaNV12ToRGB(srcDev, width * sizeof(uint8_t), destDev, width * sizeof(uchar3), width, height);
}

// cudaNV12ToRGB (float3)
cudaError_t cudaNV12ToRGB( void* srcDev, size_t srcPitch, float3* destDev, size_t destPitch, size_t width, size_t height )
{
	return launchNV12ToRGBA<float3>(srcDev, srcPitch, destDev, destPitch, width, height);
}

// cudaNV12ToRGB (float3)
cudaError_t cudaNV12ToRGB( void* srcDev, float3* destDev, size_t width, size_t height )
{
	return cudaNV12ToRGB(srcDev, width * sizeof(uint8_t), destDev, width * sizeof(float3), width, height);
}

// cudaNV12ToRGBA (uchar4)
cudaError_t cudaNV12ToRGBA( void* srcDev, size_t srcPitch, uchar4* destDev, size_t destPitch, size_t width, size_t height )
{
	return launchNV12ToRGBA<uchar4>(srcDev, srcPitch, destDev, destPitch, width, height);
}

// cudaNV12ToRGBA (uchar4)
cudaError_t cudaNV12ToRGBA( void* srcDev, uchar4* destDev, size_t width, size_t height )
{
	return cudaNV12ToRGBA(srcDev, width * sizeof(uint8_t), destDev, width * sizeof(uchar4), width, height);
}

// cudaNV12ToRGBA (float4)
cudaError_t cudaNV12ToRGBA( void* srcDev, size_t srcPitch, float4* destDev, size_t destPitch, size_t width, size_t height )
{
	return launchNV12ToRGBA<float4>(srcDev, srcPitch, destDev, destPitch, width, height);
}

// cudaNV12ToRGBA (float4)
cudaError_t cudaNV12ToRGBA( void* srcDev, float4* destDev, size_t width, size_t height )
{
	return cudaNV12ToRGBA(srcDev, width * sizeof(uint8_t), destDev, width * sizeof(float4), width, height);
}


#if 0
// cudaNV12SetupColorspace
cudaError_t cudaNV12SetupColorspace( float hue )
{
	const float hueSin = sin(hue);
	const float hueCos = cos(hue);

	float hueCSC[9];

	const bool itu601 = false;

	if( itu601 /*CSC == ITU601*/)
	{
		//CCIR 601
		hueCSC[0] = 1.1644f;
		hueCSC[1] = hueSin * 1.5960f;
		hueCSC[2] = hueCos * 1.5960f;
		hueCSC[3] = 1.1644f;
		hueCSC[4] = (hueCos * -0.3918f) - (hueSin * 0.8130f);
		hueCSC[5] = (hueSin *  0.3918f) - (hueCos * 0.8130f);
		hueCSC[6] = 1.1644f;
		hueCSC[7] = hueCos *  2.0172f;
		hueCSC[8] = hueSin * -2.0172f;
	}
	else /*if(CSC == ITU709)*/
	{
		//CCIR 709
		hueCSC[0] = 1.0f;
		hueCSC[1] = hueSin * 1.57480f;
		hueCSC[2] = hueCos * 1.57480f;
		hueCSC[3] = 1.0;
		hueCSC[4] = (hueCos * -0.18732f) - (hueSin * 0.46812f);
		hueCSC[5] = (hueSin *  0.18732f) - (hueCos * 0.46812f);
		hueCSC[6] = 1.0f;
		hueCSC[7] = hueCos *  1.85560f;
		hueCSC[8] = hueSin * -1.85560f;
	}


	if( CUDA_FAILED(cudaMemcpyToSymbol(constHueColorSpaceMat, hueCSC, sizeof(float) * 9)) )
		return cudaErrorInvalidSymbol;

	uint32_t cudaAlpha = ((uint32_t)0xff<< 24);

	if( CUDA_FAILED(cudaMemcpyToSymbol(constAlpha, &cudaAlpha, sizeof(uint32_t))) )
		return cudaErrorInvalidSymbol;

	nv12ColorspaceSetup = true;
	return cudaSuccess;
}
#endif

