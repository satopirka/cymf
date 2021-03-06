#
# Copyright (c) 2020 Minato Sato
# All rights reserved.
#
# This source code is licensed under the license found in the
# LICENSE file in the root directory of this source tree.
#

# cython: language_level=3
# distutils: language=c++

import cython
import numpy as np
from scipy import sparse
from tqdm import tqdm

cimport numpy as np
from cython.parallel cimport prange
from libcpp cimport bool

from .evaluator import Evaluator

from libc.stdlib cimport malloc
from libc.stdlib cimport free
from libc.string cimport memcpy
from libc.string cimport memset

from .linalg cimport solvep
from .linalg cimport dot

from .math cimport sqrt
from .math cimport exp
from .math cimport square
from .math cimport M_PI

cdef extern from "util.h" namespace "cymf" nogil:
    cdef int threadid()
    cdef int cpucount()

class ExpoMF(object):
    """
    Exposure Matrix Factorization (ExpoMF)
    https://arxiv.org/pdf/1510.07025.pdf
    
    Attributes:
        num_components (int): A dimensionality of latent vector
        lam_y (double): See the paper
        weight_decay (double): A coefficient of weight decay
        W (np.ndarray[double, ndim=2]): User latent vectors
        H (np.ndarray[double, ndim=2]): Item latent vectors
    """
    def __init__(self, int num_components = 20, double lam_y = 1.0, double weight_decay = 0.01):
        """
        Args:
            num_components (int): A dimensionality of latent vector
            weight_decay (double): A coefficient of weight decay
        """
        self.num_components = num_components
        self.lam_y = lam_y
        self.weight_decay = weight_decay
        self.W = None
        self.H = None

    def fit(self, X, int num_epochs = 5, int num_threads = 1, valid_evaluator = None, bool early_stopping = False, bool verbose = True):
        """
        Training ExpoMF model with EM Algorithm

        Args:
            X: A user-item interaction matrix.
            num_epochs (int): A number of epochs.
            verbose (bool): Whether to show the progress of training.
        """
        if X is None:
            raise ValueError()

        if sparse.isspmatrix(X):
            X = X.tocsr()
        elif isinstance(X, np.ndarray):
            X = sparse.csr_matrix(X)
        else:
            raise ValueError()
        X = X.astype(np.float64)

        self.valid_evaluator = valid_evaluator
        self.valid_dcg = - np.inf
        self.count = 0
        self.early_stopping = early_stopping

        if early_stopping and self.valid_evaluator is None:
            raise ValueError()
                
        if self.W is None:
            np.random.seed(4321)
            self.W = np.random.randn(X.shape[0], self.num_components) * 0.01
        if self.H is None:
            self.H = np.random.randn(X.shape[1], self.num_components) * 0.01
        self._fit_als(X, num_epochs, num_threads, verbose)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    def _fit_als(self,
                 X,
                 int num_epochs, 
                 int num_threads,
                 bool verbose):
        cdef int epoch
        cdef int U = X.shape[0]
        cdef int I = X.shape[1]
        cdef double[:,:] _X = X.toarray()

        cdef double[:,:] Exposure = np.zeros(shape=X.shape, dtype=np.float64)
        cdef double alpha_1 = 1.0
        cdef double alpha_2 = 1.0
        cdef double[:] mu = np.ones(I) * 0.01
        cdef double lam_y = self.lam_y
        cdef int u, i
        cdef double[:,::1] W = self.W
        cdef double[:,::1] H = self.H
        cdef double[:,:] W_best = np.array(W).copy()
        cdef double[:,:] H_best = np.array(H).copy()
        cdef np.ndarray[double, ndim=2] n_ui
        cdef np.ndarray[double, ndim=2] A

        with tqdm(total=num_epochs, leave=True, ncols=100, disable=not verbose) as progress:
            for epoch in range(num_epochs):
                # for u in range(U):
                #     for i in range(I):
                #         if _X[u, i] == 1.0:
                #             Exposure[u, i] = 1.0
                #         else:
                #             n_ui = sqrt(lam_y / 2.0*M_PI) * exp(- square(lam_y) * square(dot(W[u], H[i])) / 2.)
                #             Exposure[u, i] = (n_ui+1e-8) / (n_ui+1e-8 + (1 - mu[i]) / mu[i])
                
                n_ui = sqrt(lam_y / 2.0*M_PI) * np.exp(-lam_y * np.dot(W, H.T)**2 / 2.)
                A = (n_ui + 1e-8) / (n_ui + 1e-8 + (1 - np.array(mu)) / np.array(mu))
                A[X.nonzero()] = 1.0
                Exposure = A

                self._als(X.indptr, X.indices, Exposure, self.W, self.H, num_threads)
                self._als(X.T.tocsr().indptr, X.T.tocsr().indices, Exposure.T, self.H, self.W, num_threads)

                mu = (alpha_1 + np.array(Exposure).sum(axis=0) - 1.) / (alpha_1 + alpha_2 + U - 2.)

                if self.valid_evaluator:
                    valid_dcg = self.valid_evaluator.evaluate(self.W, self.H)["DCG@5"]
                    if self.early_stopping and self.valid_dcg > valid_dcg and count > 10:
                        break
                    elif self.early_stopping and self.valid_dcg > valid_dcg:
                        count += 1
                    else:
                        count = 0
                        self.valid_dcg = valid_dcg
                        W_best = np.array(W).copy()
                        H_best = np.array(H).copy()

                progress.set_description(f"EPOCH={epoch+1:{len(str(num_epochs))}} {(', DCG@5=' + str(np.round(valid_dcg,3))) if self.valid_evaluator else ''}")
                progress.update(1)

        if self.valid_evaluator and self.early_stopping:
            self.W = np.array(W_best).copy()
            self.H = np.array(H_best).copy()

    @cython.boundscheck(False)
    @cython.wraparound(False)
    def _als(self, int[:] indptr, int[:] indices, double[:,:] Exposure, double[:,:] X, double[:,:] Y, int num_threads):
        cdef int K = X.shape[1]
        cdef int i, ptr
        cdef int index
        cdef int k, k2, j
        cdef double lam_y = self.lam_y
        cdef double[:,:] _A = (self.weight_decay/self.lam_y) * np.eye(K).astype(np.float64)
        cdef double[:,:] _b = np.zeros((K, 1)).astype(np.float64)
        cdef double* A
        cdef double* b

        num_threads = num_threads if num_threads > 0 else cpucount()
        
        for i in prange(X.shape[0], nogil=True, num_threads=num_threads, schedule="guided"):
            A = <double *> malloc(sizeof(double) * K * K) # K行K列
            b = <double *> malloc(sizeof(double) * K * 1) # K行1列
            
            if indptr[i] == indptr[i+1]:
                memset(&X[i, 0], 0, sizeof(double) * K)
                free(A)
                free(b)
                continue
            
            memcpy(A, &_A[0, 0], sizeof(double) * K * K)
            memcpy(b, &_b[0, 0], sizeof(double) * K)
            
            for ptr in range(indptr[i], indptr[i+1]):
                index = indices[ptr]
                for k in range(K):
                    b[k] += Y[index, k] * Exposure[i, index] * lam_y

            for j in range(Y.shape[0]):
                for k in range(K):
                    for k2 in range(K):
                        A[k*K+k2] += Y[j, k] * Y[j, k2] * Exposure[i, j] * lam_y
            
            solvep(A, b, K)

            for k in range(K):
                X[i, k] = b[k]
            
            free(A)
            free(b)
