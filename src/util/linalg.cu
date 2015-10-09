#include "../knet.h"

/* CUBLAS nrm2 is extremely slow.  The following is a substitute from Barret Zoph.
   Based on: http://developer.download.nvidia.com/compute/cuda/1.1-Beta/x86_website/projects/reduction/doc/reduction.pdf
*/

//for optimizing warps
//volatile must be used as register optimization will lead to wrong answers
template<typename dType>
__device__ 
void warpReduceSum(volatile dType* sdata, int tid) {
	sdata[tid] += sdata[tid + 32];
	sdata[tid] += sdata[tid + 16];
	sdata[tid] += sdata[tid + 8];
	sdata[tid] += sdata[tid + 4];
	sdata[tid] += sdata[tid + 2];
	sdata[tid] += sdata[tid + 1];
}

#define NORM_THREADS 256
template<typename dType>
__global__
void basic_compute_norm_p1(dType *d_gradient,int size,dType *result) {
	__shared__ dType buffer[NORM_THREADS];
	int i_start = threadIdx.x+blockIdx.x*blockDim.x; //start at the thread index
	int i_end = size; //end at dim
	int i_step = blockDim.x*gridDim.x; //the block dimension (aka the number of threads in the block) is the step
	int tid = threadIdx.x;


	buffer[tid] = 0;
	for(int i= i_start; i<i_end; i+=i_step) {
		buffer[tid]+=(d_gradient[i]*d_gradient[i]);
	}
	__syncthreads();

	for(int stride=NORM_THREADS/2; stride>32; stride>>=1) {
		if(tid < stride) {
			buffer[tid] += buffer[stride + tid];
		}
		__syncthreads();
	}

	if(tid<32) {
		warpReduceSum(buffer,tid);
	}
	__syncthreads();

	if(tid==0) {
		result[blockIdx.x]=buffer[0];
	}
}


template<typename dType>
__global__
void basic_compute_norm_p2(dType *temp_result,dType *final_result) {
	__shared__ dType buffer[NORM_THREADS];

	int tid = threadIdx.x;
	buffer[tid] = temp_result[tid];
	__syncthreads();

	for(int stride=NORM_THREADS/2; stride>32; stride>>=1) {
		if(tid < stride) {
			buffer[tid] += buffer[stride + tid];
		}
		__syncthreads();
	}

	if(tid<32) {
		warpReduceSum(buffer,tid);
	}
	__syncthreads();

	if(tid==0) {
		final_result[0]=buffer[0];
	}
}

extern "C" {
  float vecnorm32(float *d_array,int size) {
    float norm;
    static float *d_temp_result;
    static float *d_result;
    if (d_temp_result == NULL) cudaMalloc(&d_temp_result, NORM_THREADS*sizeof(float));
    if (d_result == NULL) cudaMalloc(&d_result, 1*sizeof(float));
    basic_compute_norm_p1<<<NORM_THREADS,NORM_THREADS>>>(d_array,size,d_temp_result);
    basic_compute_norm_p2<<<1,NORM_THREADS>>>(d_temp_result,d_result);
    cudaMemcpy(&norm,d_result,1*sizeof(float),cudaMemcpyDeviceToHost);
    return sqrt(norm);
  }

  double vecnorm64(double *d_array,int size) {
    double norm;
    static double *d_temp_result;
    static double *d_result;
    if (d_temp_result == NULL) cudaMalloc(&d_temp_result, NORM_THREADS*sizeof(double));
    if (d_result == NULL) cudaMalloc(&d_result, 1*sizeof(double));
    basic_compute_norm_p1<<<NORM_THREADS,NORM_THREADS>>>(d_array,size,d_temp_result);
    basic_compute_norm_p2<<<1,NORM_THREADS>>>(d_temp_result,d_result);
    cudaMemcpy(&norm,d_result,1*sizeof(double),cudaMemcpyDeviceToHost);
    return sqrt(norm);
  }
}

/*
  The following functions multiply two sparse matrices into a dense matrix.
  The sparse matrices are in 1-based csc format.
  Ast_mul_Bs uses the transpose of the first arg and a simpler algorithm.
  x(nd,nx) s(nd,ns) -> k(nx,ns)
  As_mul_Bs uses the fast algorithm from the Julia sparse code.
  x(nx,nd) s(nd,ns) -> k(nx,ns)
  The difference in speed is significant on the CPU but only around 50% on the GPU
*/

__global__ void _Ast_mul_Bs_32(int nx, int ns, float *xval, int *xrow, int *xcol, float *sval, int *srow, int *scol, float *k) {
  int i, n, x1, x2, xc, xr, s1, s2, sc, sr;
  i = threadIdx.x + blockIdx.x * blockDim.x;
  n = nx*ns;
  while (i < n) {
    double ki = 0;
    xc = i % nx;
    sc = i / nx;
    x1 = xcol[xc]-1; x2 = xcol[xc+1]-1;
    s1 = scol[sc]-1; s2 = scol[sc+1]-1;
    while ((x1 < x2) && (s1 < s2)) {
      xr = xrow[x1]; sr = srow[s1];
      if (sr < xr) s1++;
      else if (xr < sr) x1++;
      else ki += xval[x1++]*sval[s1++];
    }
    k[i] = ki;
    i += blockDim.x * gridDim.x;
  }
}

__global__ void _Ast_mul_Bs_64(int nx, int ns, double *xval, int *xrow, int *xcol, double *sval, int *srow, int *scol, double *k) {
  int i, n, x1, x2, xc, xr, s1, s2, sc, sr;
  i = threadIdx.x + blockIdx.x * blockDim.x;
  n = nx*ns;
  while (i < n) {
    double ki = 0;
    xc = i % nx;
    sc = i / nx;
    x1 = xcol[xc]-1; x2 = xcol[xc+1]-1;
    s1 = scol[sc]-1; s2 = scol[sc+1]-1;
    while ((x1 < x2) && (s1 < s2)) {
      xr = xrow[x1]; sr = srow[s1];
      if (sr < xr) s1++;
      else if (xr < sr) x1++;
      else ki += xval[x1++]*sval[s1++];
    }
    k[i] = ki;
    i += blockDim.x * gridDim.x;
  }
}

__global__ void _As_mul_Bs_32(int mx, int ns, float *xval, int *xrow, int *xcol, float *sval, int *srow, int *scol, float *k) {
  int s0, s1, sp, sc, sr, x0, x1, xp, xc, xr, k0, k1, kp;
  float sv, xv;
  sc = threadIdx.x + blockIdx.x * blockDim.x;
  while (sc < ns) {	// sc: 0-based column for s
    k0 = mx*sc;		// k[k0]: first element of k[:,sc]
    k1 = k0+mx;		// k[k1-1]: last element of k[:,sc]
    for (kp = k0; kp < k1; kp++) k[kp] = 0;
    s0 = scol[sc]-1;    // first element of s[:,sc] is at sval[s0] (scol entries are 1-based)
    s1 = scol[sc+1]-1;  // last element of s[:,sc] is at sval[s1-1]
    for (sp = s0; sp < s1; sp++) {
      sr = srow[sp]-1;  // sr: 0-based row for s (srow entries are 1-based)
      sv = sval[sp];	// sv: s[sr,sc] (0-based)
      xc = sr;		// xc: 0-based column for x (=sr)
      x0 = xcol[xc]-1;  // first element of x[:,xc] is at xval[x0]
      x1 = xcol[xc+1]-1; // last element of x[:,xc] is at xval[x1-1]
      for (xp = x0; xp < x1; xp++) {
	xr = xrow[xp]-1; // xr: 0-based row for x
	xv = xval[xp];	 // xv: x[xr,xc=sr], now we can set k[xr,sc]
	k[k0+xr] += xv*sv;
      }
    }
    sc += blockDim.x * gridDim.x;
  }
}

__global__ void _As_mul_Bs_64(int mx, int ns, double *xval, int *xrow, int *xcol, double *sval, int *srow, int *scol, double *k) {
  int s0, s1, sp, sc, sr, x0, x1, xp, xc, xr, k0, k1, kp;
  double sv, xv;
  sc = threadIdx.x + blockIdx.x * blockDim.x;
  while (sc < ns) {	// sc: 0-based column for s
    k0 = mx*sc;		// k[k0]: first element of k[:,sc]
    k1 = k0+mx;		// k[k1-1]: last element of k[:,sc]
    for (kp = k0; kp < k1; kp++) k[kp] = 0;
    s0 = scol[sc]-1;    // first element of s[:,sc] is at sval[s0] (scol entries are 1-based)
    s1 = scol[sc+1]-1;  // last element of s[:,sc] is at sval[s1-1]
    for (sp = s0; sp < s1; sp++) {
      sr = srow[sp]-1;  // sr: 0-based row for s (srow entries are 1-based)
      sv = sval[sp];	// sv: s[sr,sc] (0-based)
      xc = sr;		// xc: 0-based column for x (=sr)
      x0 = xcol[xc]-1;  // first element of x[:,xc] is at xval[x0]
      x1 = xcol[xc+1]-1; // last element of x[:,xc] is at xval[x1-1]
      for (xp = x0; xp < x1; xp++) {
	xr = xrow[xp]-1; // xr: 0-based row for x
	xv = xval[xp];	 // xv: x[xr,xc=sr], now we can set k[xr,sc]
	k[k0+xr] += xv*sv;
      }
    }
    sc += blockDim.x * gridDim.x;
  }
}

__global__ void _A_mul_Bs_32(int mx, int ns, float *x, float *sval, int *srow, int *scol, float *k) {
  int s0, s1, sp, sc, sr, x0, xr, k0, k1, kp;
  float sv, xv;
  sc = threadIdx.x + blockIdx.x * blockDim.x;
  while (sc < ns) {	// sc: 0-based column for s and k to be processed
    k0 = mx*sc;		// k[k0]: first element of k[:,sc]
    k1 = k0+mx;		// k[k1-1]: last element of k[:,sc]
    for (kp = k0; kp < k1; kp++) k[kp] = 0;
    s0 = scol[sc]-1;    // first element of s[:,sc] is at sval[s0] (scol entries are 1-based)
    s1 = scol[sc+1]-1;  // last element of s[:,sc] is at sval[s1-1]
    for (sp = s0; sp < s1; sp++) {
      sr = srow[sp]-1;  // sr: 0-based row for s (srow entries are 1-based)
      sv = sval[sp];	// sv: s[sr,sc] (0-based), this value multiplies the sr'th column of x
      x0 = mx*sr;	// x[x0]: first element of x[:,sr]
      for (xr = 0; xr < mx; xr++) {
	xv = x[x0+xr];     // xv: x[xr,sr], now we can set k[xr,sc]
	k[k0+xr] += xv*sv;
      }
    }
    sc += blockDim.x * gridDim.x;
  }
}

__global__ void _A_mul_Bs_64(int mx, int ns, double *x, double *sval, int *srow, int *scol, double *k) {
  int s0, s1, sp, sc, sr, x0, xr, k0, k1, kp;
  double sv, xv;
  sc = threadIdx.x + blockIdx.x * blockDim.x;
  while (sc < ns) {	// sc: 0-based column for s and k to be processed
    k0 = mx*sc;		// k[k0]: first element of k[:,sc]
    k1 = k0+mx;		// k[k1-1]: last element of k[:,sc]
    for (kp = k0; kp < k1; kp++) k[kp] = 0;
    s0 = scol[sc]-1;    // first element of s[:,sc] is at sval[s0] (scol entries are 1-based)
    s1 = scol[sc+1]-1;  // last element of s[:,sc] is at sval[s1-1]
    for (sp = s0; sp < s1; sp++) {
      sr = srow[sp]-1;  // sr: 0-based row for s (srow entries are 1-based)
      sv = sval[sp];	// sv: s[sr,sc] (0-based), this value multiplies the sr'th column of x
      x0 = mx*sr;	// x[x0]: first element of x[:,sr]
      for (xr = 0; xr < mx; xr++) {
	xv = x[x0+xr];     // xv: x[xr,sr], now we can set k[xr,sc]
	k[k0+xr] += xv*sv;
      }
    }
    sc += blockDim.x * gridDim.x;
  }
}


/* We will do dw=dy*x' where x is a sparse matrix one column of x at a time. */

__global__ void _A_mul_Bst_32(int my, int xc, float *dy, float *xval, int *xrow, int *xcol, float *dw) {
  // dw[wr,wc] += dy[yr,yc] * x[xr,xc]  where wr=yr, wc=xr, yc=xc
  int t, n, xp, xr, yp, yr, wp;
  t = threadIdx.x + blockIdx.x * blockDim.x;
  n = xcol[xc+1] - xcol[xc];
  while (t < n) {
    xp = xcol[xc] + t - 1;
    xr = xrow[xp] - 1;
    for (yr = 0; yr < my; yr++) {
      yp = yr + xc * my;
      wp = yr + xr * my;
      dw[wp] += dy[yp] * xval[xp];
    }
    t += blockDim.x * gridDim.x;
  }
}

__global__ void _A_mul_Bst_64(int my, int xc, double *dy, double *xval, int *xrow, int *xcol, double *dw) {
  // dw[wr,wc] += dy[yr,yc] * x[xr,xc]  where wr=yr, wc=xr, yc=xc
  int t, n, xp, xr, yp, yr, wp;
  t = threadIdx.x + blockIdx.x * blockDim.x;
  n = xcol[xc+1] - xcol[xc];
  while (t < n) {
    xp = xcol[xc] + t - 1;
    xr = xrow[xp] - 1;
    for (yr = 0; yr < my; yr++) {
      yp = yr + xc * my;
      wp = yr + xr * my;
      dw[wp] += dy[yp] * xval[xp];
    }
    t += blockDim.x * gridDim.x;
  }
}

__global__ void _axpb32(int n, float a, float b, float *x) {
  int i = threadIdx.x + blockIdx.x * blockDim.x;
  while (i < n) {
    x[i] = a * x[i] + b;
    i += blockDim.x * gridDim.x;
  }
}

__global__ void _axpb64(int n, double a, double b, double *x) {
  int i = threadIdx.x + blockIdx.x * blockDim.x;
  while (i < n) {
    x[i] = a * x[i] + b;
    i += blockDim.x * gridDim.x;
  }
}

__global__ void _mul2_32(int n, float *x, float *y, float *z) {
  int i = threadIdx.x + blockIdx.x * blockDim.x;
  while (i < n) {
    z[i] = y[i] * x[i];
    i += blockDim.x * gridDim.x;
  }
}

__global__ void _mul2_64(int n, double *x, double *y, double *z) {
  int i = threadIdx.x + blockIdx.x * blockDim.x;
  while (i < n) {
    z[i] = y[i] * x[i];
    i += blockDim.x * gridDim.x;
  }
}

__global__ void _axpy32csr(int m, int n, float alpha,
			   int nnzA,
			   const float *csrValA,
			   const int *csrRowPtrA,
			   const int *csrColIndA,
			   float *B) {
  int nz = threadIdx.x + blockIdx.x * blockDim.x;
  while (nz < nnzA) {
    float val = alpha * csrValA[nz];
    int col = csrColIndA[nz]-1;
    int row; for (row = 0; nz > csrRowPtrA[row+1]-2; row++);
    B[col * m + row] += val;
    nz += blockDim.x * gridDim.x;
  }
}

__global__ void _axpy64csr(int m, int n, double alpha,
			   int nnzA,
			   const double *csrValA,
			   const int *csrRowPtrA,
			   const int *csrColIndA,
			   double *B) {
  int nz = threadIdx.x + blockIdx.x * blockDim.x;
  while (nz < nnzA) {
    double val = alpha * csrValA[nz];
    int col = csrColIndA[nz]-1;
    int row; for (row = 0; nz > csrRowPtrA[row+1]-2; row++);
    B[col * m + row] += val;
    nz += blockDim.x * gridDim.x;
  }
}

extern "C" {

  void axpy32csr(int m, int n, float alpha, int nnzA, const float *csrValA, const int *csrRowPtrA, const int *csrColIndA, float *B) KCALL(_axpy32csr,m,n,alpha,nnzA,csrValA,csrRowPtrA,csrColIndA,B);
  void axpy64csr(int m, int n, double alpha, int nnzA, const double *csrValA, const int *csrRowPtrA, const int *csrColIndA, double *B) KCALL(_axpy64csr,m,n,alpha,nnzA,csrValA,csrRowPtrA,csrColIndA,B);


  void A_mul_Bs_32(int mx, int ns,  float *x,  float *sval, int *srow, int *scol,  float *k) KCALL(_A_mul_Bs_32,mx,ns,x,sval,srow,scol,k);
  void A_mul_Bs_64(int mx, int ns, double *x, double *sval, int *srow, int *scol, double *k) KCALL(_A_mul_Bs_64,mx,ns,x,sval,srow,scol,k);
  void Ast_mul_Bs_32(int nx, int ns,  float *xval, int *xrow, int *xcol,  float *sval, int *srow, int *scol,  float *k) KCALL(_Ast_mul_Bs_32,nx,ns,xval,xrow,xcol,sval,srow,scol,k);
  void Ast_mul_Bs_64(int nx, int ns, double *xval, int *xrow, int *xcol, double *sval, int *srow, int *scol, double *k) KCALL(_Ast_mul_Bs_64,nx,ns,xval,xrow,xcol,sval,srow,scol,k);
  void As_mul_Bs_32(int mx, int ns,  float *xval, int *xrow, int *xcol,  float *sval, int *srow, int *scol,  float *k) KCALL(_As_mul_Bs_32,mx,ns,xval,xrow,xcol,sval,srow,scol,k);
  void As_mul_Bs_64(int mx, int ns, double *xval, int *xrow, int *xcol, double *sval, int *srow, int *scol, double *k) KCALL(_As_mul_Bs_64,mx,ns,xval,xrow,xcol,sval,srow,scol,k);

  void A_mul_Bst_32(int my, int ny, int mx, float *dy, float *xval, int *xrow, int *xcol, float *dw) {
    // dy[my,ny] * x[mx,nx]' -> w[mw,nw]   where ny=nx, mw=my, nw=mx
    CUDA(cudaMemset(dw, 0, my * mx * sizeof(float)));
    CUDA(cudaDeviceSynchronize());
    for (int xc=0; xc<ny; xc++) {		// do one column of x at a time (row of x')
      KCALL(_A_mul_Bst_32,my,xc,dy,xval,xrow,xcol,dw);
      CUDA(cudaDeviceSynchronize());
    }
  }

  void A_mul_Bst_64(int my, int ny, int mx, double *dy, double *xval, int *xrow, int *xcol, double *dw) {
    // dy[my,ny] * x[mx,nx]' -> w[mw,nw]   where ny=nx, mw=my, nw=mx
    CUDA(cudaMemset(dw, 0, my * mx * sizeof(double)));
    CUDA(cudaDeviceSynchronize());
    for (int xc=0; xc<ny; xc++) {		// do one column of x at a time (row of x')
      KCALL(_A_mul_Bst_64,my,xc,dy,xval,xrow,xcol,dw);
      CUDA(cudaDeviceSynchronize());
    }
  }

  // To test the blk,thr parameters:
  // #define KCALL(f,...) {f<<<BLK,THR>>>(__VA_ARGS__); CUDA(cudaGetLastError()); }
  void At_test(int blk,int thr,int nx, int ns,  float *xval, int *xrow, int *xcol,  float *sval, int *srow, int *scol, float *k) {_Ast_mul_Bs_32<<<blk,thr>>>(nx,ns,xval,xrow,xcol,sval,srow,scol,k); CUDA(cudaGetLastError()); }
  void A_test(int blk,int thr,int nx, int ns, float *xval, int *xrow, int *xcol, float *sval, int *srow, int *scol, float *k) {_As_mul_Bs_32<<<blk,thr>>>(nx,ns,xval,xrow,xcol,sval,srow,scol,k); CUDA(cudaGetLastError()); }


  void axpb32(int n, float a, float b, float *x) KCALL(_axpb32,n,a,b,x);
  void axpb64(int n, double a, double b, double *x) KCALL(_axpb64,n,a,b,x);

  void mul2_32(int n, float  *x, float  *y,  float *z) KCALL(_mul2_32,n,x,y,z);
  void mul2_64(int n, double *x, double *y, double *z) KCALL(_mul2_64,n,x,y,z);
}