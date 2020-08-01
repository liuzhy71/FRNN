/*
 * Copyright 1993-2009 NVIDIA Corporation.  All rights reserved.
 *
 * NVIDIA Corporation and its licensors retain all intellectual property and 
 * proprietary rights in and to this software and related documentation and 
 * any modifications thereto.  Any use, reproduction, disclosure, or distribution 
 * of this software and related documentation without an express license 
 * agreement from NVIDIA Corporation is strictly prohibited.
 * 
 */

#include "prefix_sum.cuh"
#include <assert.h>

#ifndef _SCAN_BEST_KERNEL_CU_
#define _SCAN_BEST_KERNEL_CU_

// Define this to more rigorously avoid bank conflicts, 
// even at the lower (root) levels of the tree
// Note that due to the higher addressing overhead, performance 
// is lower with ZERO_BANK_CONFLICTS enabled.  It is provided
// as an example.
//#define ZERO_BANK_CONFLICTS 


#ifdef ZERO_BANK_CONFLICTS
#define CONFLICT_FREE_OFFSET(index) ((index) >> LOG_NUM_BANKS + (index) >> (2*LOG_NUM_BANKS))
#else
#define CONFLICT_FREE_OFFSET(index) ((index) >> LOG_NUM_BANKS)
#endif

///////////////////////////////////////////////////////////////////////////////
// Work-efficient compute implementation of scan, one thread per 2 elements
// Work-efficient: O(log(n)) steps, and O(n) adds.
// Also shared storage efficient: Uses n + n/NUM_BANKS shared memory -- no ping-ponging
// Also avoids most bank conflicts using single-element offsets every NUM_BANKS elements.
//
// In addition, If ZERO_BANK_CONFLICTS is defined, uses 
//     n + n/NUM_BANKS + n/(NUM_BANKS*NUM_BANKS) 
// shared memory. If ZERO_BANK_CONFLICTS is defined, avoids ALL bank conflicts using 
// single-element offsets every NUM_BANKS elements, plus additional single-element offsets 
// after every NUM_BANKS^2 elements.
//
// Uses a balanced tree type algorithm.  See Blelloch, 1990 "Prefix Sums 
// and Their Applications", or Prins and Chatterjee PRAM course notes:
// https://www.cs.unc.edu/~prins/Classes/633/Handouts/pram.pdf
// 
// This work-efficient version is based on the algorithm presented in Guy Blelloch's
// excellent paper "Prefix sums and their applications".
// http://www.cs.cmu.edu/~blelloch/papers/Ble93.pdf
//
// Pro: Work Efficient, very few bank conflicts (or zero if ZERO_BANK_CONFLICTS is defined)
// Con: More instructions to compute bank-conflict-free shared memory addressing,
// and slightly more shared memory storage used.
//

template <bool isNP2> __device__ void loadSharedChunkFromMem (float *s_data, const float *g_idata, int n, int baseIndex, int& ai, int& bi, int& mem_ai, int& mem_bi, int& bankOffsetA, int& bankOffsetB )
{
    int thid = threadIdx.x;
    mem_ai = baseIndex + threadIdx.x;
    mem_bi = mem_ai + blockDim.x;

    ai = thid;
    bi = thid + blockDim.x;
    bankOffsetA = CONFLICT_FREE_OFFSET(ai);		    // compute spacing to avoid bank conflicts
    bankOffsetB = CONFLICT_FREE_OFFSET(bi);
    
	s_data[ai + bankOffsetA] = g_idata[mem_ai];		// Cache the computational window in shared memory pad values beyond n with zeros
    
    if (isNP2) { // compile-time decision
        s_data[bi + bankOffsetB] = (bi < n) ? g_idata[mem_bi] : 0; 
    } else {
        s_data[bi + bankOffsetB] = g_idata[mem_bi]; 
    }
}


template <bool isNP2> __device__ void loadSharedChunkFromMemInt (int *s_data, const int *g_idata, int n, int baseIndex, int& ai, int& bi, int& mem_ai, int& mem_bi, int& bankOffsetA, int& bankOffsetB )
{
    int thid = threadIdx.x;
    mem_ai = baseIndex + threadIdx.x;
    mem_bi = mem_ai + blockDim.x;

    ai = thid;
    bi = thid + blockDim.x;
    bankOffsetA = CONFLICT_FREE_OFFSET(ai);		    // compute spacing to avoid bank conflicts
    bankOffsetB = CONFLICT_FREE_OFFSET(bi);
    
	s_data[ai + bankOffsetA] = g_idata[mem_ai];		// Cache the computational window in shared memory pad values beyond n with zeros
    
    if (isNP2) { // compile-time decision
        s_data[bi + bankOffsetB] = (bi < n) ? g_idata[mem_bi] : 0; 
    } else {
        s_data[bi + bankOffsetB] = g_idata[mem_bi]; 
    }
}

template <bool isNP2> __device__ void storeSharedChunkToMem(float* g_odata, const float* s_data, int n, int ai, int bi, int mem_ai, int mem_bi,int bankOffsetA, int bankOffsetB)
{
    __syncthreads();

    g_odata[mem_ai] = s_data[ai + bankOffsetA];			// write results to global memory
    if (isNP2) { // compile-time decision
        if (bi < n) g_odata[mem_bi] = s_data[bi + bankOffsetB]; 
    } else {
        g_odata[mem_bi] = s_data[bi + bankOffsetB]; 
    }
}
template <bool isNP2> __device__ void storeSharedChunkToMemInt (int* g_odata, const int* s_data, int n, int ai, int bi, int mem_ai, int mem_bi,int bankOffsetA, int bankOffsetB)
{
    __syncthreads();

    g_odata[mem_ai] = s_data[ai + bankOffsetA];			// write results to global memory
    if (isNP2) { // compile-time decision
        if (bi < n) g_odata[mem_bi] = s_data[bi + bankOffsetB]; 
    } else {
        g_odata[mem_bi] = s_data[bi + bankOffsetB]; 
    }
}


template <bool storeSum> __device__ void clearLastElement( float* s_data, float *g_blockSums, int blockIndex)
{
    if (threadIdx.x == 0) {
        int index = (blockDim.x << 1) - 1;
        index += CONFLICT_FREE_OFFSET(index);        
        if (storeSum) { // compile-time decision
            // write this block's total sum to the corresponding index in the blockSums array
            g_blockSums[blockIndex] = s_data[index];
        }
        s_data[index] = 0;		// zero the last element in the scan so it will propagate back to the front
    }
}

template <bool storeSum> __device__ void clearLastElementInt ( int* s_data, int *g_blockSums, int blockIndex)
{
    if (threadIdx.x == 0) {
        int index = (blockDim.x << 1) - 1;
        index += CONFLICT_FREE_OFFSET(index);        
        if (storeSum) { // compile-time decision
            // write this block's total sum to the corresponding index in the blockSums array
            g_blockSums[blockIndex] = s_data[index];
        }
        s_data[index] = 0;		// zero the last element in the scan so it will propagate back to the front
    }
}


__device__ unsigned int buildSum(float *s_data)
{
    unsigned int thid = threadIdx.x;
    unsigned int stride = 1;
    
    // build the sum in place up the tree
    for (int d = blockDim.x; d > 0; d >>= 1) {
        __syncthreads();

        if (thid < d) {
            int i  = __mul24(__mul24(2, stride), thid);
            int ai = i + stride - 1;
            int bi = ai + stride;
            ai += CONFLICT_FREE_OFFSET(ai);
            bi += CONFLICT_FREE_OFFSET(bi);
            s_data[bi] += s_data[ai];
        }
        stride *= 2;
    }
    return stride;
}
__device__ unsigned int buildSumInt (int *s_data)
{
    unsigned int thid = threadIdx.x;
    unsigned int stride = 1;
    
    // build the sum in place up the tree
    for (int d = blockDim.x; d > 0; d >>= 1) {
        __syncthreads();
        if (thid < d) {
            int i  = __mul24(__mul24(2, stride), thid);
            int ai = i + stride - 1;
            int bi = ai + stride;
            ai += CONFLICT_FREE_OFFSET(ai);
            bi += CONFLICT_FREE_OFFSET(bi);
            s_data[bi] += s_data[ai];
        }
        stride *= 2;
    }
    return stride;
}

__device__ void scanRootToLeaves(float *s_data, unsigned int stride)
{
     unsigned int thid = threadIdx.x;

    // traverse down the tree building the scan in place
    for (int d = 1; d <= blockDim.x; d *= 2) {
        stride >>= 1;
        __syncthreads();

        if (thid < d) {
            int i  = __mul24(__mul24(2, stride), thid);
            int ai = i + stride - 1;
            int bi = ai + stride;
            ai += CONFLICT_FREE_OFFSET(ai);
            bi += CONFLICT_FREE_OFFSET(bi);
            float t = s_data[ai];
            s_data[ai] = s_data[bi];
            s_data[bi] += t;
        }
    }
}

__device__ void scanRootToLeavesInt (int *s_data, unsigned int stride)
{
     unsigned int thid = threadIdx.x;

    // traverse down the tree building the scan in place
    for (int d = 1; d <= blockDim.x; d *= 2) {
        stride >>= 1;
        __syncthreads();

        if (thid < d) {
            int i  = __mul24(__mul24(2, stride), thid);
            int ai = i + stride - 1;
            int bi = ai + stride;
            ai += CONFLICT_FREE_OFFSET(ai);
            bi += CONFLICT_FREE_OFFSET(bi);
            int t = s_data[ai];
            s_data[ai] = s_data[bi];
            s_data[bi] += t;
        }
    }
}

template <bool storeSum> __device__ void prescanBlock(float *data, int blockIndex, float *blockSums)
{
    int stride = buildSum (data);               // build the sum in place up the tree
    clearLastElement<storeSum> (data, blockSums, (blockIndex == 0) ? blockIdx.x : blockIndex);
    scanRootToLeaves (data, stride);            // traverse down tree to build the scan 
}
template <bool storeSum> __device__ void prescanBlockInt (int *data, int blockIndex, int *blockSums)
{
    int stride = buildSumInt (data);               // build the sum in place up the tree
    clearLastElementInt <storeSum>(data, blockSums, (blockIndex == 0) ? blockIdx.x : blockIndex);
    scanRootToLeavesInt (data, stride);            // traverse down tree to build the scan 
}

__global__ void uniformAdd (float *g_data, float *uniforms, int n, int blockOffset, int baseIndex)
{
    __shared__ float uni;
    if (threadIdx.x == 0) uni = uniforms[blockIdx.x + blockOffset];    
    unsigned int address = __mul24(blockIdx.x, (blockDim.x << 1)) + baseIndex + threadIdx.x; 

    __syncthreads();    
    // note two adds per thread
    g_data[address]              += uni;
    g_data[address + blockDim.x] += (threadIdx.x + blockDim.x < n) * uni;
}
__global__ void uniformAddInt (int *g_data, int *uniforms, int n, int blockOffset, int baseIndex)
{
    __shared__ int uni;
    if (threadIdx.x == 0) uni = uniforms[blockIdx.x + blockOffset];    
    unsigned int address = __mul24(blockIdx.x, (blockDim.x << 1)) + baseIndex + threadIdx.x; 

    __syncthreads();    
    // note two adds per thread
    g_data[address]              += uni;
    g_data[address + blockDim.x] += (threadIdx.x + blockDim.x < n) * uni;
}


#endif // #ifndef _SCAN_BEST_KERNEL_CU_


// includes, kernels
#include <assert.h>

template <bool storeSum, bool isNP2> __global__ void prescan(float *g_odata, const float *g_idata, float *g_blockSums, int n, int blockIndex, int baseIndex) {
    int ai, bi, mem_ai, mem_bi, bankOffsetA, bankOffsetB;
    extern __shared__ float s_data[];
    loadSharedChunkFromMem<isNP2>(s_data, g_idata, n, (baseIndex == 0) ? __mul24(blockIdx.x, (blockDim.x << 1)):baseIndex, ai, bi, mem_ai, mem_bi, bankOffsetA, bankOffsetB); 
    prescanBlock<storeSum>(s_data, blockIndex, g_blockSums); 
    storeSharedChunkToMem<isNP2>(g_odata, s_data, n, ai, bi, mem_ai, mem_bi, bankOffsetA, bankOffsetB); 
}

template <bool storeSum, bool isNP2> __global__ void prescanInt (int *g_odata, const int *g_idata, int *g_blockSums, int n, int blockIndex, int baseIndex) {
    int ai, bi, mem_ai, mem_bi, bankOffsetA, bankOffsetB;
    extern __shared__ int s_dataInt [];
    loadSharedChunkFromMemInt <isNP2>(s_dataInt, g_idata, n, (baseIndex == 0) ? __mul24(blockIdx.x, (blockDim.x << 1)):baseIndex, ai, bi, mem_ai, mem_bi, bankOffsetA, bankOffsetB); 
    prescanBlockInt<storeSum>(s_dataInt, blockIndex, g_blockSums); 
    storeSharedChunkToMemInt <isNP2>(g_odata, s_dataInt, n, ai, bi, mem_ai, mem_bi, bankOffsetA, bankOffsetB); 
}


inline bool isPowerOfTwo(int n) { return ((n&(n-1))==0) ; }

inline int floorPow2(int n) {
	#ifdef WIN32
		return 1 << (int)logb((float)n);
	#else
		int exp;
		frexp((float)n, &exp);
		return 1 << (exp - 1);
	#endif
}


#define BLOCK_SIZE 256

float**			g_scanBlockSums = 0;
int**			g_scanBlockSumsInt = 0;
unsigned int	g_numEltsAllocated = 0;
unsigned int	g_numLevelsAllocated = 0;

void preallocBlockSums(unsigned int maxNumElements)
{
    assert(g_numEltsAllocated == 0); // shouldn't be called 

    g_numEltsAllocated = maxNumElements;
    unsigned int blockSize = BLOCK_SIZE; // max size of the thread blocks
    unsigned int numElts = maxNumElements;
    int level = 0;

    do {       
        unsigned int numBlocks =   max(1, (int)ceil((float)numElts / (2.f * blockSize)));
        if (numBlocks > 1) level++;
        numElts = numBlocks;
    } while (numElts > 1);

    g_scanBlockSums = (float**) malloc(level * sizeof(float*));
    g_numLevelsAllocated = level;
    
    numElts = maxNumElements;
    level = 0;
    
    do {       
        unsigned int numBlocks = max(1, (int)ceil((float)numElts / (2.f * blockSize)));
        if (numBlocks > 1) 
			cudaCheck ( cudaMalloc((void**) &g_scanBlockSums[level++], numBlocks * sizeof(float)), "Malloc prescanBlockSums g_scanBlockSums");
        numElts = numBlocks;
    } while (numElts > 1);

}
void preallocBlockSumsInt (unsigned int maxNumElements)
{
    assert(g_numEltsAllocated == 0); // shouldn't be called 

    g_numEltsAllocated = maxNumElements;
    unsigned int blockSize = BLOCK_SIZE; // max size of the thread blocks
    unsigned int numElts = maxNumElements;
    int level = 0;

    do {       
        unsigned int numBlocks =   max(1, (int)ceil((float)numElts / (2.f * blockSize)));
        if (numBlocks > 1) level++;
        numElts = numBlocks;
    } while (numElts > 1);

    g_scanBlockSumsInt = (int**) malloc(level * sizeof(int*));
    g_numLevelsAllocated = level;
    
    numElts = maxNumElements;
    level = 0;
    
    do {       
        unsigned int numBlocks = max(1, (int)ceil((float)numElts / (2.f * blockSize)));
        if (numBlocks > 1) cudaCheck ( cudaMalloc((void**) &g_scanBlockSumsInt[level++], numBlocks * sizeof(int)), "Malloc prescanBlockSumsInt g_scanBlockSumsInt");
        numElts = numBlocks;
    } while (numElts > 1);
}

void deallocBlockSums()
{
	if ( g_scanBlockSums != 0x0 ) {
		for (unsigned int i = 0; i < g_numLevelsAllocated; i++) 
			cudaCheck ( cudaFree(g_scanBlockSums[i]), "Malloc deallocBlockSums g_scanBlockSums");
    
		free( (void**)g_scanBlockSums );
	}

    g_scanBlockSums = 0;
    g_numEltsAllocated = 0;
    g_numLevelsAllocated = 0;
}
void deallocBlockSumsInt()
{
	if ( g_scanBlockSums != 0x0 ) {
		for (unsigned int i = 0; i < g_numLevelsAllocated; i++) 
			cudaCheck ( cudaFree(g_scanBlockSumsInt[i]), "Malloc deallocBlockSumsInt g_scanBlockSumsInt");
		free( (void**)g_scanBlockSumsInt );
	}

    g_scanBlockSumsInt = 0;
    g_numEltsAllocated = 0;
    g_numLevelsAllocated = 0;
}



void prescanArrayRecursive (float *outArray, const float *inArray, int numElements, int level)
{
    unsigned int blockSize = BLOCK_SIZE; // max size of the thread blocks
    unsigned int numBlocks = max(1, (int)ceil((float)numElements / (2.f * blockSize)));
    unsigned int numThreads;

    if (numBlocks > 1)
        numThreads = blockSize;
    else if (isPowerOfTwo(numElements))
        numThreads = numElements / 2;
    else
        numThreads = floorPow2(numElements);

    unsigned int numEltsPerBlock = numThreads * 2;

    // if this is a non-power-of-2 array, the last block will be non-full
    // compute the smallest power of 2 able to compute its scan.
    unsigned int numEltsLastBlock = numElements - (numBlocks-1) * numEltsPerBlock;
    unsigned int numThreadsLastBlock = max(1, numEltsLastBlock / 2);
    unsigned int np2LastBlock = 0;
    unsigned int sharedMemLastBlock = 0;
    
    if (numEltsLastBlock != numEltsPerBlock) {
        np2LastBlock = 1;
        if(!isPowerOfTwo(numEltsLastBlock)) numThreadsLastBlock = floorPow2(numEltsLastBlock);            
        unsigned int extraSpace = (2 * numThreadsLastBlock) / NUM_BANKS;
        sharedMemLastBlock = sizeof(float) * (2 * numThreadsLastBlock + extraSpace);
    }

    // padding space is used to avoid shared memory bank conflicts
    unsigned int extraSpace = numEltsPerBlock / NUM_BANKS;
    unsigned int sharedMemSize = sizeof(float) * (numEltsPerBlock + extraSpace);

	#ifdef DEBUG
		if (numBlocks > 1) assert(g_numEltsAllocated >= numElements);
	#endif

    // setup execution parameters
    // if NP2, we process the last block separately
    dim3  grid(max(1, numBlocks - np2LastBlock), 1, 1); 
    dim3  threads(numThreads, 1, 1);

    // execute the scan
    if (numBlocks > 1) {
        prescan<true, false><<< grid, threads, sharedMemSize >>> (outArray, inArray,  g_scanBlockSums[level], numThreads * 2, 0, 0);
        if (np2LastBlock) {
            prescan<true, true><<< 1, numThreadsLastBlock, sharedMemLastBlock >>> (outArray, inArray, g_scanBlockSums[level], numEltsLastBlock, numBlocks - 1, numElements - numEltsLastBlock);
        }

        // After scanning all the sub-blocks, we are mostly done.  But now we 
        // need to take all of the last values of the sub-blocks and scan those.  
        // This will give us a new value that must be added to each block to 
        // get the final results.
        // recursive (CPU) call
        prescanArrayRecursive (g_scanBlockSums[level], g_scanBlockSums[level], numBlocks, level+1);

        uniformAdd<<< grid, threads >>> (outArray, g_scanBlockSums[level], numElements - numEltsLastBlock, 0, 0);
        if (np2LastBlock) {
            uniformAdd<<< 1, numThreadsLastBlock >>>(outArray, g_scanBlockSums[level], numEltsLastBlock, numBlocks - 1, numElements - numEltsLastBlock);
        }
    } else if (isPowerOfTwo(numElements)) {
        prescan<false, false><<< grid, threads, sharedMemSize >>> (outArray, inArray, 0, numThreads * 2, 0, 0);
    } else {
        prescan<false, true><<< grid, threads, sharedMemSize >>> (outArray, inArray, 0, numElements, 0, 0);
    }
}

void prescanArrayRecursiveInt (int *outArray, const int *inArray, int numElements, int level)
{
    unsigned int blockSize = BLOCK_SIZE; // max size of the thread blocks
    unsigned int numBlocks = max(1, (int)ceil((float)numElements / (2.f * blockSize)));
    unsigned int numThreads;

    if (numBlocks > 1)
        numThreads = blockSize;
    else if (isPowerOfTwo(numElements))
        numThreads = numElements / 2;
    else
        numThreads = floorPow2(numElements);

    unsigned int numEltsPerBlock = numThreads * 2;

    // if this is a non-power-of-2 array, the last block will be non-full
    // compute the smallest power of 2 able to compute its scan.
    unsigned int numEltsLastBlock = numElements - (numBlocks-1) * numEltsPerBlock;
    unsigned int numThreadsLastBlock = max(1, numEltsLastBlock / 2);
    unsigned int np2LastBlock = 0;
    unsigned int sharedMemLastBlock = 0;
    
    if (numEltsLastBlock != numEltsPerBlock) {
        np2LastBlock = 1;
        if(!isPowerOfTwo(numEltsLastBlock)) numThreadsLastBlock = floorPow2(numEltsLastBlock);            
        unsigned int extraSpace = (2 * numThreadsLastBlock) / NUM_BANKS;
        sharedMemLastBlock = sizeof(float) * (2 * numThreadsLastBlock + extraSpace);
    }

    // padding space is used to avoid shared memory bank conflicts
    unsigned int extraSpace = numEltsPerBlock / NUM_BANKS;
    unsigned int sharedMemSize = sizeof(float) * (numEltsPerBlock + extraSpace);

	#ifdef DEBUG
		if (numBlocks > 1) assert(g_numEltsAllocated >= numElements);
	#endif

    // setup execution parameters
    // if NP2, we process the last block separately
    dim3  grid(max(1, numBlocks - np2LastBlock), 1, 1); 
    dim3  threads(numThreads, 1, 1);

    // execute the scan
    if (numBlocks > 1) {
        prescanInt <true, false><<< grid, threads, sharedMemSize >>> (outArray, inArray,  g_scanBlockSumsInt[level], numThreads * 2, 0, 0);
        if (np2LastBlock) {
            prescanInt <true, true><<< 1, numThreadsLastBlock, sharedMemLastBlock >>> (outArray, inArray, g_scanBlockSumsInt[level], numEltsLastBlock, numBlocks - 1, numElements - numEltsLastBlock);
        }

        // After scanning all the sub-blocks, we are mostly done.  But now we 
        // need to take all of the last values of the sub-blocks and scan those.  
        // This will give us a new value that must be added to each block to 
        // get the final results.
        // recursive (CPU) call
        prescanArrayRecursiveInt (g_scanBlockSumsInt[level], g_scanBlockSumsInt[level], numBlocks, level+1);

        uniformAddInt <<< grid, threads >>> (outArray, g_scanBlockSumsInt[level], numElements - numEltsLastBlock, 0, 0);
        if (np2LastBlock) {
            uniformAddInt <<< 1, numThreadsLastBlock >>>(outArray, g_scanBlockSumsInt[level], numEltsLastBlock, numBlocks - 1, numElements - numEltsLastBlock);
        }
    } else if (isPowerOfTwo(numElements)) {
        prescanInt <false, false><<< grid, threads, sharedMemSize >>> (outArray, inArray, 0, numThreads * 2, 0, 0);
    } else {
        prescanInt <false, true><<< grid, threads, sharedMemSize >>> (outArray, inArray, 0, numElements, 0, 0);
    }
}

/*
void prescanArray ( float *d_odata, float *d_idata, int num )
{	
	// preform prefix sum
	preallocBlockSums( num );
    prescanArrayRecursive ( d_odata, d_idata, num, 0);
	deallocBlockSums();
}
void prescanArrayInt ( int *d_odata, int *d_idata, int num )
{	
	// preform prefix sum
	preallocBlockSumsInt ( num );
    prescanArrayRecursiveInt ( d_odata, d_idata, num, 0);
	deallocBlockSumsInt ();
}

char* d_idata = NULL;
char* d_odata = NULL;

void prefixSum ( int num )
{
	prescanArray ( (float*) d_odata, (float*) d_idata, num );
}

void prefixSumInt ( int num )
{	
	prescanArrayInt ( (int*) d_odata, (int*) d_idata, num );
}

void prefixSumToGPU ( char* inArray, int num, int siz )
{
    cudaCheck ( cudaMalloc( (void**) &d_idata, num*siz ),	"Malloc prefixumSimToGPU idata");
    cudaCheck ( cudaMalloc( (void**) &d_odata, num*siz ),	"Malloc prefixumSimToGPU odata" );
    cudaCheck ( cudaMemcpy( d_idata, inArray, num*siz, cudaMemcpyHostToDevice),	"Memcpy inArray->idata" );
}
void prefixSumFromGPU ( char* outArray, int num, int siz )
{		
	cudaCheck ( cudaMemcpy( outArray, d_odata, num*siz, cudaMemcpyDeviceToHost), "Memcpy odata->outArray" );
	cudaCheck ( cudaFree( d_idata ), "Free idata" );
    cudaCheck ( cudaFree( d_odata ), "Free odata" );
	d_idata = NULL;
	d_odata = NULL;
}
*/

/*
// from fluid3
#define BLOCK_SIZE 256

float**			g_scanBlockSums = 0;
int**			g_scanBlockSumsInt = 0;
unsigned int	g_numEltsAllocated = 0;
unsigned int	g_numLevelsAllocated = 0;

void preallocBlockSums(unsigned int maxNumElements)
{
    assert(g_numEltsAllocated == 0); // shouldn't be called 

    g_numEltsAllocated = maxNumElements;
    unsigned int blockSize = BLOCK_SIZE; // max size of the thread blocks
    unsigned int numElts = maxNumElements;
    int level = 0;

    do {       
        unsigned int numBlocks =   max(1, (int)ceil((float)numElts / (2.f * blockSize)));
        if (numBlocks > 1) level++;
        numElts = numBlocks;
    } while (numElts > 1);

    g_scanBlockSums = (float**) malloc(level * sizeof(float*));
    g_numLevelsAllocated = level;
    
    numElts = maxNumElements;
    level = 0;
    
    do {       
        unsigned int numBlocks = max(1, (int)ceil((float)numElts / (2.f * blockSize)));
        if (numBlocks > 1) 
			cudaCheck ( cudaMalloc((void**) &g_scanBlockSums[level++], numBlocks * sizeof(float)), "Malloc prescanBlockSums g_scanBlockSums");
        numElts = numBlocks;
    } while (numElts > 1);

}
void preallocBlockSumsInt (unsigned int maxNumElements)
{
    assert(g_numEltsAllocated == 0); // shouldn't be called 

    g_numEltsAllocated = maxNumElements;
    unsigned int blockSize = BLOCK_SIZE; // max size of the thread blocks
    unsigned int numElts = maxNumElements;
    int level = 0;

    do {       
        unsigned int numBlocks =   max(1, (int)ceil((float)numElts / (2.f * blockSize)));
        if (numBlocks > 1) level++;
        numElts = numBlocks;
    } while (numElts > 1);

    g_scanBlockSumsInt = (int**) malloc(level * sizeof(int*));
    g_numLevelsAllocated = level;
    
    numElts = maxNumElements;
    level = 0;
    
    do {       
        unsigned int numBlocks = max(1, (int)ceil((float)numElts / (2.f * blockSize)));
        if (numBlocks > 1) cudaCheck ( cudaMalloc((void**) &g_scanBlockSumsInt[level++], numBlocks * sizeof(int)), "Malloc prescanBlockSumsInt g_scanBlockSumsInt");
        numElts = numBlocks;
    } while (numElts > 1);
}

void deallocBlockSums()
{
	if ( g_scanBlockSums != 0x0 ) {
		for (unsigned int i = 0; i < g_numLevelsAllocated; i++) 
			cudaCheck ( cudaFree(g_scanBlockSums[i]), "Malloc deallocBlockSums g_scanBlockSums");
    
		free( (void**)g_scanBlockSums );
	}

    g_scanBlockSums = 0;
    g_numEltsAllocated = 0;
    g_numLevelsAllocated = 0;
}
void deallocBlockSumsInt()
{
	if ( g_scanBlockSums != 0x0 ) {
		for (unsigned int i = 0; i < g_numLevelsAllocated; i++) 
			cudaCheck ( cudaFree(g_scanBlockSumsInt[i]), "Malloc deallocBlockSumsInt g_scanBlockSumsInt");
		free( (void**)g_scanBlockSumsInt );
	}

    g_scanBlockSumsInt = 0;
    g_numEltsAllocated = 0;
    g_numLevelsAllocated = 0;
}


inline bool isPowerOfTwo(int n) { return ((n&(n-1))==0) ; }


inline int floorPow2(int n) {
	#ifdef WIN32
		return 1 << (int)logb((float)n);
	#else
		int exp;
		frexp((float)n, &exp);
		return 1 << (exp - 1);
	#endif
}

template <bool storeSum, bool isNP2> __global__ void prescanInt (int *g_odata, const int *g_idata, int *g_blockSums, int n, int blockIndex, int baseIndex) {
    int ai, bi, mem_ai, mem_bi, bankOffsetA, bankOffsetB;
    extern __shared__ int s_dataInt [];
    loadSharedChunkFromMemInt <isNP2>(s_dataInt, g_idata, n, (baseIndex == 0) ? __mul24(blockIdx.x, (blockDim.x << 1)):baseIndex, ai, bi, mem_ai, mem_bi, bankOffsetA, bankOffsetB); 
    prescanBlockInt<storeSum>(s_dataInt, blockIndex, g_blockSums); 
    storeSharedChunkToMemInt <isNP2>(g_odata, s_dataInt, n, ai, bi, mem_ai, mem_bi, bankOffsetA, bankOffsetB); 
}

int** g_scanBlockSumsInt = 0;

void prescanArrayRecursiveInt (int *outArray, const int *inArray, int numElements, int level)
{
    unsigned int blockSize = BLOCK_SIZE; // max size of the thread blocks
    unsigned int numBlocks = max(1, (int)ceil((float)numElements / (2.f * blockSize)));
    unsigned int numThreads;

    if (numBlocks > 1)
        numThreads = blockSize;
    else if (isPowerOfTwo(numElements))
        numThreads = numElements / 2;
    else
        numThreads = floorPow2(numElements);

    unsigned int numEltsPerBlock = numThreads * 2;

    // if this is a non-power-of-2 array, the last block will be non-full
    // compute the smallest power of 2 able to compute its scan.
    unsigned int numEltsLastBlock = numElements - (numBlocks-1) * numEltsPerBlock;
    unsigned int numThreadsLastBlock = max(1, numEltsLastBlock / 2);
    unsigned int np2LastBlock = 0;
    unsigned int sharedMemLastBlock = 0;
    
    if (numEltsLastBlock != numEltsPerBlock) {
        np2LastBlock = 1;
        if(!isPowerOfTwo(numEltsLastBlock)) numThreadsLastBlock = floorPow2(numEltsLastBlock);            
        unsigned int extraSpace = (2 * numThreadsLastBlock) / NUM_BANKS;
        sharedMemLastBlock = sizeof(float) * (2 * numThreadsLastBlock + extraSpace);
    }

    // padding space is used to avoid shared memory bank conflicts
    unsigned int extraSpace = numEltsPerBlock / NUM_BANKS;
    unsigned int sharedMemSize = sizeof(float) * (numEltsPerBlock + extraSpace);

	#ifdef DEBUG
		if (numBlocks > 1) assert(g_numEltsAllocated >= numElements);
	#endif

    // setup execution parameters
    // if NP2, we process the last block separately
    dim3  grid(max(1, numBlocks - np2LastBlock), 1, 1); 
    dim3  threads(numThreads, 1, 1);

    // execute the scan
    if (numBlocks > 1) {
        prescanInt <true, false><<< grid, threads, sharedMemSize >>> (outArray, inArray,  g_scanBlockSumsInt[level], numThreads * 2, 0, 0);
        if (np2LastBlock) {
            prescanInt <true, true><<< 1, numThreadsLastBlock, sharedMemLastBlock >>> (outArray, inArray, g_scanBlockSumsInt[level], numEltsLastBlock, numBlocks - 1, numElements - numEltsLastBlock);
        }

        // After scanning all the sub-blocks, we are mostly done.  But now we 
        // need to take all of the last values of the sub-blocks and scan those.  
        // This will give us a new value that must be added to each block to 
        // get the final results.
        // recursive (CPU) call
        prescanArrayRecursiveInt (g_scanBlockSumsInt[level], g_scanBlockSumsInt[level], numBlocks, level+1);

        uniformAddInt <<< grid, threads >>> (outArray, g_scanBlockSumsInt[level], numElements - numEltsLastBlock, 0, 0);
        if (np2LastBlock) {
            uniformAddInt <<< 1, numThreadsLastBlock >>>(outArray, g_scanBlockSumsInt[level], numEltsLastBlock, numBlocks - 1, numElements - numEltsLastBlock);
        }
    } else if (isPowerOfTwo(numElements)) {
        prescanInt <false, false><<< grid, threads, sharedMemSize >>> (outArray, inArray, 0, numThreads * 2, 0, 0);
    } else {
        prescanInt <false, true><<< grid, threads, sharedMemSize >>> (outArray, inArray, 0, numElements, 0, 0);
    }
}
*/

bool cudaCheck ( cudaError_t status, const std::string& msg )
{
	if ( status != cudaSuccess ) {
		printf ( "CUDA ERROR: %s\n", cudaGetErrorString ( status ) );
		return false;
	} else {
		//app_printf ( "%s. OK.\n", msg );
	}
	return true;
}