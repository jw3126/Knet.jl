/* Read and write layers and arrays in HDF5 format */
/* TODO: add error handling */
/* TODO: do not hardcode float */

#include <assert.h>
#include <cuda_runtime.h>
#include <hdf5.h>
#include <hdf5_hl.h>
#include "jnet.h"
#include "jnet_h5.h"

static inline void *copy_to_gpu(void *cptr, size_t n) {
  if (cptr == NULL || n == 0) return NULL;
  void *gptr; cudaMalloc((void **) &gptr, n);
  cudaMemcpy(gptr, cptr, n, cudaMemcpyHostToDevice);
  return gptr;
}

static inline void *copy_to_cpu(void *gptr, size_t n) {
  if (gptr == NULL || n == 0) return NULL;
  void *cptr = malloc(n);
  cudaMemcpy(cptr, gptr, n, cudaMemcpyDeviceToHost);
  return cptr;
}

static inline void check_dims(int *nptr, int n) {
  if (nptr == NULL) assert(n == 1);
  else if (*nptr == 0) *nptr = n;
  else assert(*nptr == n);
}

static inline void h5read_to_gpu(hid_t id, const char *name, int *nrows, int *ncols, float **data) {
  if (H5LTfind_dataset(id, (name+1))) {
    hsize_t dims[2];
    H5LTget_dataset_info(id,name,dims,NULL,NULL);
    check_dims(nrows, dims[1]);
    check_dims(ncols, dims[0]);
    int size = dims[0]*dims[1]*sizeof(float);
    if (size > 0) {
      float *cpuArray = (float *) malloc(size);
      H5LTread_dataset_float(id, name, cpuArray);
      *data = (float *) copy_to_gpu(cpuArray, size);
      free(cpuArray);
    } else {
      *data = NULL;
    }
  } else {
    *data = NULL;
  }
}

// TODO: these will break if attr is not of the right type and size=1

static inline int h5attr_int(hid_t id, const char *attr) {
  int ans = 0;
  if (H5LTfind_attribute(id, attr))
    H5LTget_attribute_int(id, "/", attr, &ans);
  return ans;
}

static inline int h5attr_float(hid_t id, const char *attr) {
  float ans = 0;
  if (H5LTfind_attribute(id, attr))
    H5LTget_attribute_float(id, "/", attr, &ans);
  return ans;
}

Layer h5read_layer(const char *fname) {
  Layer l = layer(NOOP, 0, 0, NULL, NULL);
  hid_t id = H5Fopen(fname, H5F_ACC_RDONLY, H5P_DEFAULT);
  l->type = (LayerType) h5attr_int(id, "type");
  l->adagrad = h5attr_int(id, "adagrad");
  l->nesterov = h5attr_int(id, "nesterov");
  l->learningRate = h5attr_float(id, "learningRate");
  l->momentum = h5attr_float(id, "momentum");
  l->dropout = h5attr_float(id, "dropout");
  l->maxnorm = h5attr_float(id, "maxnorm");
  l->L1 = h5attr_float(id, "L1");
  l->L2 = h5attr_float(id, "L2");
  h5read_to_gpu(id, "/w", &l->wrows, &l->wcols, &l->w);
  h5read_to_gpu(id, "/b", &l->wrows, NULL, &l->b);
  h5read_to_gpu(id, "/dw", &l->wrows, &l->wcols, &l->dw);
  h5read_to_gpu(id, "/db", &l->wrows, NULL, &l->db);
  h5read_to_gpu(id, "/dw1", &l->wrows, &l->wcols, &l->dw1);
  h5read_to_gpu(id, "/db1", &l->wrows, NULL, &l->db1);
  h5read_to_gpu(id, "/dw2", &l->wrows, &l->wcols, &l->dw2);
  h5read_to_gpu(id, "/db2", &l->wrows, NULL, &l->db2);
  H5Fclose(id);
  return l;
}

static inline void h5write_from_gpu(hid_t id, const char *name, int nrows, int ncols, float *data) {
  float *cptr = (float *) copy_to_cpu(data, nrows * ncols * sizeof(float));
  hsize_t dims[2] = { ncols, nrows };
  H5LTmake_dataset_float(id, name, 2, dims, cptr);
  free(cptr);
}

void h5write_layer(const char *fname, Layer l) {
  hid_t id = H5Fcreate (fname, H5F_ACC_TRUNC, H5P_DEFAULT, H5P_DEFAULT);
  int type = (int) l->type;
  H5LTset_attribute_int(id, "/", "type", &type, 1);
  H5LTset_attribute_int(id, "/", "adagrad", &l->adagrad, 1);
  H5LTset_attribute_int(id, "/", "nesterov", &l->nesterov, 1);
  H5LTset_attribute_float(id, "/", "learningRate", &l->learningRate, 1);
  H5LTset_attribute_float(id, "/", "momentum", &l->momentum, 1);
  H5LTset_attribute_float(id, "/", "dropout", &l->dropout, 1);
  H5LTset_attribute_float(id, "/", "maxnorm", &l->maxnorm, 1);
  H5LTset_attribute_float(id, "/", "L1", &l->L1, 1);
  H5LTset_attribute_float(id, "/", "L2", &l->L2, 1);
  h5write_from_gpu(id, "/w", l->wrows, l->wcols, l->w);
  h5write_from_gpu(id, "/b", l->wrows, 1, l->b);
  h5write_from_gpu(id, "/dw", l->wrows, l->wcols, l->dw);
  h5write_from_gpu(id, "/db", l->wrows, 1, l->db);
  h5write_from_gpu(id, "/dw1", l->wrows, l->wcols, l->dw1);
  h5write_from_gpu(id, "/db1", l->wrows, 1, l->db1);
  h5write_from_gpu(id, "/dw2", l->wrows, l->wcols, l->dw2);
  h5write_from_gpu(id, "/db2", l->wrows, 1, l->db2);
  H5Fclose(id);
}

void h5read(const char *fname, int *nrows, int *ncols, float **data) {
  const char *name = "/data";
  hid_t id = H5Fopen(fname, H5F_ACC_RDONLY, H5P_DEFAULT);
  hsize_t dims[2]; H5LTget_dataset_info(id,name,dims,NULL,NULL);
  int size = dims[0]*dims[1]*sizeof(float);
  if (size > 0) {
    *nrows = dims[1];
    *ncols = dims[0];
    *data = (float *) malloc(size);
    H5LTread_dataset_float(id, name, *data);
  } else {
    *nrows = 0;
    *ncols = 0;
    *data = NULL;
  }
  H5Fclose(id);
}

void h5write(const char *fname, int nrows, int ncols, float *data) {
  const char *name = "/data";
  hid_t id = H5Fcreate (fname, H5F_ACC_TRUNC, H5P_DEFAULT, H5P_DEFAULT);
  hsize_t dims[2] = { ncols, nrows };
  H5LTmake_dataset_float(id, name, 2, dims, data);
  H5Fclose(id);
}
