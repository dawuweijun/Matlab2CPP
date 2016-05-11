
#include "heat2d.h"

void Manage_Memory(int phase, int tid, float **h_u, float **d_u, float **d_un){
  if (phase==0) {
    // Allocate whole domain in host (master thread)
    *h_u = (float*)malloc(NY*NX*sizeof(float));
  }
  if (phase==1) {
    // Allocate whole domain in device (GPU thread)
    cudaError_t Error = cudaSetDevice(tid);
    if (DEBUG) printf("CUDA error (cudaSetDevice) = %s\n",cudaGetErrorString(Error));
    Error = cudaMalloc((void**)d_u ,NY*NX*sizeof(float));
    if (DEBUG) printf("CUDA error (cudaMalloc) = %s\n",cudaGetErrorString(Error));
    Error = cudaMalloc((void**)d_un,NY*NX*sizeof(float));
    if (DEBUG) printf("CUDA error (cudaMalloc) = %s\n",cudaGetErrorString(Error));
  }
  if (phase==2) {
    // Free the whole domain variables (master thread)
    free(*h_u);
    cudaError_t Error;
    Error = cudaFree(*d_u);
    if (DEBUG) printf("CUDA error (cudaFree) = %s\n",cudaGetErrorString(Error));
    Error = cudaFree(*d_un);
    if (DEBUG) printf("CUDA error (cudaFree) = %s\n",cudaGetErrorString(Error));
  }
}

void Manage_Comms(int phase, int tid, float **h_u, float **d_u) {
  // Manage CPU-GPU communicastions
  if (DEBUG) printf(":::::::: Performing Comms (phase %d) ::::::::\n",phase);
  
  if (phase == 0) {
    // move h_u (from HOST) to d_u (to GPU)
    cudaError_t Error = cudaMemcpy(*d_u,*h_u,NY*NX*sizeof(float),cudaMemcpyHostToDevice);
    if (DEBUG) printf("CUDA error (memcpy h -> d ) = %s\n",cudaGetErrorString(Error));
  }
  if (phase == 1) {
    // move d_u (from GPU) to h_u (to HOST)
    cudaError_t Error = cudaMemcpy(*h_u,*d_u,NY*NX*sizeof(float),cudaMemcpyDeviceToHost);
    if (DEBUG) printf("CUDA error (memcpy d -> h ) = %s\n",cudaGetErrorString(Error));
  }
}

void Save_Results(float *u){
  // print result to txt file
  FILE *pFile = fopen("result.txt", "w");
  if (pFile != NULL) {
    for (int j = 0; j < NY; j++) {
      for (int i = 0; i < NX; i++) {      
	fprintf(pFile, "%d\t %d\t %g\n",j,i,u[i+NX*j]);
      }
    }
    fclose(pFile);
  } else {
    printf("Unable to save to file\n");
  }
}

/******************************/
/* TEMPERATURE INITIALIZATION */
/******************************/
__global__ void SetIC_onDevice(float *u0){
int i, j, o, IC; 
  // threads id 
  i = threadIdx.x + blockIdx.x*blockDim.x;
  j = threadIdx.y + blockIdx.y*blockDim.y;

  // select IC
  IC=2;

  switch (IC) {
  case 1: {
	// set all domain's cells equal to zero
	o = i+NX*j;  u0[o] = 0.0;
	// set BCs in the domain 
	if (j==0)    u0[o] = 0.0; // bottom
	if (i==0)    u0[o] = 0.0; // left
	if (j==NY-1) u0[o] = 1.0; // top
	if (i==NX-1) u0[o] = 1.0; // right
    break;
  }
  case 2: {
    float u_bl = 0.7f;
    float u_br = 1.0f;
    float u_tl = 0.7f;
    float u_tr = 1.0f;

	// set all domain's cells equal to zero
	o = i+NX*j;  u0[o] = 0.0;
	// set BCs in the domain 
	if (j==0)    u0[o] = u_bl + (u_br-u_bl)*i/(NX+1); // bottom
	if (j==NY-1) u0[o] = u_tl + (u_tr-u_tl)*i/(NX+1); // top
	if (i==0)    u0[o] = u_bl + (u_tl-u_bl)*j/(NY+1); // left
	if (i==NX-1) u0[o] = u_br + (u_tr-u_br)*j/(NY+1); // right
    break;
  }
  case 3: {
	// set all domain's cells equal to zero
	o = i+NX*j;  u0[o] = 0.0;
	// set left wall to 1
	if (i==NX-1) u0[o] = 1.0;
    break;
  }
    // here to add another IC
  }
}

void Call_GPU_Init(float **u0){
  // Load the initial condition
  dim3 threads(32,32);
  dim3 blocks((NX+1)/32,(NY+1)/32); 
  SetIC_onDevice<<<blocks, threads>>>(*u0);
}

__global__ void Laplace2d(const float * __restrict__ u, float * __restrict__ un){
  int o, n, s, e, w; 
  // Threads id
  const int i = threadIdx.x + blockIdx.x*blockDim.x;
  const int j = threadIdx.y + blockIdx.y*blockDim.y;

  o = i + (NX*j);         // node( j,i,k )      n
  n = (i==NX-1) ? o:o+NX; // node(j+1,i,k)      |
  s = (i==0)    ? o:o-NX; // node(j-1,i,k)   w--o--e
  e = (j==NY-1) ? o:o+1;  // node(j,i+1,k)      |
  w = (j==0)    ? o:o-1;  // node(j,i-1,k)      s

  // only update "interior" nodes
  if(i>0 && i<NX-1 && j>0 && j<NY-1) {
    un[o] = u[o] + KX*(u[e]-2*u[o]+u[w]) + KY*(u[n]-2*u[o]+u[s]);
  } else {
    un[o] = u[o];
  }
}

__global__ void Laplace2d_v2(const float * __restrict__ u, float * __restrict__ un){
  // Global Threads id
  int j = threadIdx.x + blockIdx.x*blockDim.x;
  int i = threadIdx.y + blockIdx.y*blockDim.y;

  // Local Threads id
  int lj = threadIdx.x;
  int li = threadIdx.y;

  // e_XX --> variables refers to expanded shared memory location in order to accomodate halo elements
  //Current Local ID with radius offset.
  int e_li = li + RADIUS;
  int e_lj = lj + RADIUS;

  // Variable pointing at top and bottom neighbouring location
  int e_li_prev = e_li - 1;
  int e_li_next = e_li + 1;

  // Variable pointing at left and right neighbouring location
  int e_lj_prev = e_lj - 1;
  int e_lj_next = e_lj + 1;

  __shared__ float sData [NJ+2*RADIUS][NI+2*RADIUS];
  unsigned int index = (i)* NY + (j) ;

  // copy top and bottom halo
  if (li<RADIUS) { 
    //Copy Top Halo Element
    if (blockIdx.y > 0) // Boundary check
      sData[li][e_lj] = u[index - RADIUS * NY];
    //Copy Bottom Halo Element
    if (blockIdx.y < (gridDim.y-1)) // Boundary check
      sData[e_li+NJ][e_lj] = u[index + NJ * NY];
  }

  // copy left and right halo
  if (lj<RADIUS) { 
    if( blockIdx.x > 0) // Boundary check
      sData[e_li][lj] = u[index - RADIUS];
    if(blockIdx.x < (gridDim.x-1)) // Boundary check
      sData[e_li][e_lj+NI] = u[index + NI];
  }
	
  // copy current location
  sData[e_li][e_lj] = u[index]; 

  __syncthreads( );


  // only update "interior" nodes
  if(i>0 && i<NX-1 && j>0 && j<NY-1) {
    un[index] = sData[e_li][e_lj]
      + KX*(sData[e_li_prev][e_lj]-2*sData[e_li][e_lj]+sData[e_li_next][e_lj]) 
      + KY*(sData[e_li][e_lj_prev]-2*sData[e_li][e_lj]+sData[e_li][e_lj_next]);
  } else {
    un[index] = sData[e_li][e_lj];
  }
}

void Call_Laplace(float **d_u, float **d_un) {
  // Produce one iteration of the laplace operator
  dim3 threads(NI,NJ);
  dim3 blocks((NX+NI-1)/NI,(NY+NJ-1)/NJ); 
  //Laplace2d<<<blocks,threads>>>(*d_u,*d_un);
  Laplace2d_v2<<<blocks,threads>>>(*d_u,*d_un);
  if (DEBUG) printf("CUDA error (Jacobi_Method) %s\n",cudaGetErrorString(cudaPeekAtLastError()));
  cudaError_t Error = cudaDeviceSynchronize();
  if (DEBUG) printf("CUDA error (Jacobi_Method Synchronize) %s\n",cudaGetErrorString(Error));
}
