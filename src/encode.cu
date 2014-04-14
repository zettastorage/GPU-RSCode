/*
 * =====================================================================================
 *
 *       Filename:  encode.cu
 *
 *    Description:  
 *
 *        Version:  1.0
 *        Created:  12/05/2012 10:42:32 PM
 *       Revision:  none
 *       Compiler:  nvcc
 *
 *         Author:  Shuai YUAN (yszheda AT gmail.com), 
 *        Company:  
 *
 * =====================================================================================
 */

#include <stdio.h>
#include <cuda.h>
#include <stdlib.h>
#include <stdint.h>
#include <math.h>
#include "matrix.h"

void write_metadata(char *fileName, int totalSize, int parityBlockNum, int nativeBlockNum, uint8_t* encodingMatrix)
{
	FILE *fp;
	if((fp = fopen(fileName, "wb")) == NULL)
	{
		printf("Cannot open META file!\n");
		exit(0);
	}
	fprintf(fp, "%d\n", totalSize);
	fprintf(fp, "%d %d\n", parityBlockNum, nativeBlockNum);
	for (int i = 0; i < nativeBlockNum; ++i)
	{
		for (int j = 0; j < nativeBlockNum; ++j)
		{
			if (i == j)
			{
				fprintf(fp, "1 ");
			}
			else
			{
				fprintf(fp, "0 ");
			}
		}
		fprintf(fp, "\n");
	}
	for (int i = 0; i < parityBlockNum; ++i)
	{
		for (int j = 0; j < nativeBlockNum; ++j)
		{
			fprintf(fp, "%d ", encodingMatrix[i * nativeBlockNum + j]);
		}
		fprintf(fp, "\n");
	}
	fclose(fp);
}

extern "C"
void encode(char *fileName, uint8_t *dataBuf, uint8_t *codeBuf, int nativeBlockNum, int parityBlockNum, int chunkSize, int totalSize)
{
	uint8_t *dataBuf_d;		//device
	uint8_t *codeBuf_d;		//device
	int dataSize = nativeBlockNum * chunkSize * sizeof(uint8_t);
	int codeSize = parityBlockNum * chunkSize * sizeof(uint8_t);

	float totalComputationTime = 0;
	float totalCommunicationTime = 0;
	// compute total execution time
	float totalTime;
	cudaEvent_t totalStart, totalStop;
	// create event
	cudaEventCreate(&totalStart);
	cudaEventCreate(&totalStop);
	cudaEventRecord(totalStart);

	cudaMalloc((void **) &dataBuf_d, dataSize);
//	cudaMemset(dataBuf_d, 0, dataSize);
	cudaMalloc((void **) &codeBuf_d, codeSize);
//	cudaMemset(codeBuf_d, 0, codeSize);

	// compute step execution time
	float stepTime;
	cudaEvent_t stepStart, stepStop;
	// create event
	cudaEventCreate(&stepStart);
	cudaEventCreate(&stepStop);

	// record event
	cudaEventRecord(stepStart);
	cudaMemcpy(dataBuf_d, dataBuf, dataSize, cudaMemcpyHostToDevice);
	// record event and synchronize
	cudaEventRecord(stepStop);
	cudaEventSynchronize(stepStop);
	// get event elapsed time
	cudaEventElapsedTime(&stepTime, stepStart, stepStop);
	printf("Copy data from CPU to GPU: %fms\n", stepTime);
	totalCommunicationTime += stepTime;

	uint8_t *encodingMatrix;	//host
	uint8_t *encodingMatrix_d;	//device
	int matrixSize = parityBlockNum * nativeBlockNum * sizeof(uint8_t);
//	encodingMatrix = (uint8_t*) malloc(matrixSize);
	cudaMallocHost((void **)&encodingMatrix, matrixSize);
	cudaMalloc((void **) &encodingMatrix_d, matrixSize);

	// record event
	cudaEventRecord(stepStart);
	dim3 blk(parityBlockNum, nativeBlockNum);
	gen_encoding_matrix<<<1, blk>>>(encodingMatrix_d, parityBlockNum, nativeBlockNum);
//	cudaDeviceSynchronize();
	// record event and synchronize
	cudaEventRecord(stepStop);
	cudaEventSynchronize(stepStop);
	// get event elapsed time
	cudaEventElapsedTime(&stepTime, stepStart, stepStop);
	printf("Generating encoding matrix completed: %fms\n", stepTime);
	totalComputationTime += stepTime;

	// record event
	cudaEventRecord(stepStart);
	cudaMemcpy(encodingMatrix, encodingMatrix_d, matrixSize, cudaMemcpyDeviceToHost);
	// record event and synchronize
	cudaEventRecord(stepStop);
	cudaEventSynchronize(stepStop);
	// get event elapsed time
	cudaEventElapsedTime(&stepTime, stepStart, stepStop);
	printf("Copy encoding matrix from GPU to CPU: %fms\n", stepTime);
	totalCommunicationTime += stepTime;

	stepTime = encode_chunk(dataBuf_d, encodingMatrix_d, codeBuf_d, nativeBlockNum, parityBlockNum, chunkSize);
	printf("Encoding file completed: %fms\n", stepTime);
	totalComputationTime += stepTime;

	// record event
	cudaEventRecord(stepStart);
	cudaMemcpy(codeBuf, codeBuf_d, codeSize, cudaMemcpyDeviceToHost);
	// record event and synchronize
	cudaEventRecord(stepStop);
	cudaEventSynchronize(stepStop);
	// get event elapsed time
	cudaEventElapsedTime(&stepTime, stepStart, stepStop);
	printf("copy code from GPU to CPU: %fms\n", stepTime);
	totalCommunicationTime += stepTime;

	cudaFree(encodingMatrix_d);
	cudaFree(dataBuf_d);
	cudaFree(codeBuf_d);

	// record event and synchronize
	cudaEventRecord(totalStop);
	cudaEventSynchronize(totalStop);
	// get event elapsed time
	cudaEventElapsedTime(&totalTime, totalStart, totalStop);
	printf("Total computation time: %fms\n", totalComputationTime);
	printf("Total communication time: %fms\n", totalCommunicationTime);
	printf("Total GPU encoding time: %fms\n", totalTime);

	char metadata_file_name[strlen(fileName) + 15];
	sprintf(metadata_file_name, "%s.METADATA", fileName);
	write_metadata(metadata_file_name, totalSize, parityBlockNum, nativeBlockNum, encodingMatrix);
//	free(encodingMatrix);
	cudaFreeHost(encodingMatrix);
}

extern "C"
void encode_file(char *fileName, int nativeBlockNum, int parityBlockNum)
{
	int chunkSize = 1;
	int totalSize;

	FILE *fp_in;
	FILE *fp_out;
	if((fp_in = fopen(fileName,"rb")) == NULL)
	{
		printf("Cannot open source file!\n");
		exit(0);
	}

	fseek(fp_in, 0L, SEEK_END);
	// ftell() get the total size of the file
	totalSize = ftell(fp_in);
	chunkSize = (totalSize / nativeBlockNum) + ( totalSize%nativeBlockNum != 0 ); 
//	chunkSize = (ftell(fp_in) / nativeBlockNum) + ( ftell(fp_in)%nativeBlockNum != 0 ); 
//	chunkSize = (int) (ceil( (long double) (ftell(fp_in) / nativeBlockNum)) ); 

	cudaSetDevice(1);
	uint8_t *dataBuf;		//host
	uint8_t *codeBuf;		//host
	int dataSize = nativeBlockNum * chunkSize * sizeof(uint8_t);
	int codeSize = parityBlockNum * chunkSize * sizeof(uint8_t);
//	dataBuf = (uint8_t*) malloc(dataSize);
	cudaMallocHost((void **)&dataBuf, dataSize);
	memset(dataBuf, 0, dataSize);
//	codeBuf = (uint8_t*) malloc(codeSize);
	cudaMallocHost((void **)&codeBuf, codeSize);
	memset(codeBuf, 0, codeSize);
	
	for(int i = 0; i < nativeBlockNum; i++)
	{
		if(fseek(fp_in, i * chunkSize, SEEK_SET) == -1)
		{
			printf("fseek error!\n");
			exit(0);
		}

		if(fread(dataBuf + i * chunkSize, sizeof(uint8_t), chunkSize, fp_in) == EOF)
		{
			printf("fread error!\n");
			exit(0);
		}
	}
	fclose(fp_in);
	
	struct timespec start, end;
	clock_gettime(CLOCK_REALTIME, &start);
	encode(fileName, dataBuf, codeBuf, nativeBlockNum, parityBlockNum, chunkSize, totalSize);
	clock_gettime(CLOCK_REALTIME, &end);
	double totalTime = (double) (end.tv_sec - start.tv_sec) * 1000
			+ (double) (end.tv_nsec - start.tv_nsec) / (double) 1000000L;
	printf("Total GPU encoding time used by the total function: %fms\n", totalTime);

	char output_file_name[strlen(fileName) + 5];
	for(int i = 0; i < nativeBlockNum; i++)
	{
		sprintf(output_file_name, "_%d_%s", i, fileName);
		if((fp_out = fopen(output_file_name, "wb")) == NULL)
		{
			printf("Cannot open output file!\n");
			exit(0);
		}
		if(fwrite(dataBuf + i * chunkSize, sizeof(uint8_t), chunkSize, fp_out) != sizeof(uint8_t) * chunkSize)
		{
			printf("fwrite error!\n");
			exit(0);
		}
		fclose(fp_out);
	}
	for(int i = 0; i < parityBlockNum; i++)
	{
		sprintf(output_file_name, "_%d_%s", i + nativeBlockNum, fileName);
		if((fp_out = fopen(output_file_name, "wb")) == NULL)
		{
			printf("Cannot open output file!\n");
			exit(0);
		}
		if(fwrite(codeBuf + i * chunkSize, sizeof(uint8_t), chunkSize, fp_out) != sizeof(uint8_t)*chunkSize)
		{
			printf("fwrite error!\n");
			exit(0);
		}
		fclose(fp_out);
	}

//	free(dataBuf);
//	free(codeBuf);
	cudaFreeHost(dataBuf);
	cudaFreeHost(codeBuf);
}
