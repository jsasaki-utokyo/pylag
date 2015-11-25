from data_types_cython cimport DTYPE_INT_t, DTYPE_FLOAT_t

# PyLag cimports
from particle import Particle
from particle cimport Particle
from data_reader import DataReader
from data_reader cimport DataReader

cdef class NumIntegrator:
    cdef advect(self, DTYPE_FLOAT_t time, Particle particle, DataReader data_reader)
    
cdef class RK4Integrator(NumIntegrator):
    cdef DTYPE_FLOAT_t _time_step

    cdef advect(self, DTYPE_FLOAT_t time, Particle particle, DataReader data_reader)