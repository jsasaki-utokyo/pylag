include "constants.pxi"

import numpy as np

# Cython imports
cimport numpy as np
np.import_array()

# Data types used for constructing C data structures
from data_types_python import DTYPE_INT, DTYPE_FLOAT
from data_types_cython cimport DTYPE_INT_t, DTYPE_FLOAT_t

# PyLag python imports
from pylag.integrator import get_num_integrator
from pylag.lagrangian_stochastic_model import get_vertical_lsm
from pylag.boundary_conditions import get_vert_boundary_condition_calculator

from particle cimport Particle
from data_reader cimport DataReader
from pylag.delta cimport Delta, reset
from pylag.integrator cimport NumIntegrator
from pylag.lagrangian_stochastic_model cimport VerticalLSM
from pylag.boundary_conditions cimport VertBoundaryConditionCalculator

cdef class MockVelocityDataReader(DataReader):
    """ Test data reader for numerical integration schemes.
    
    Object passes back u/v/w velocity components for the system of ODEs:
            dx/dt = x           (1)
            dy/dt = 1.5y        (2)
            dz/dt = 0.0         (3)
    
    The velocity eqns are uncoupled and can be solved analytically, giving:
            x = x_0 * exp(t)    (4)
            y = y_0 * exp(1.5t) (5)
            z = 0.0             (6)
    
    which can be used to test different integration schemes.
    
    """
    cpdef find_host(self, DTYPE_FLOAT_t xpos_old, DTYPE_FLOAT_t ypos_old,
            DTYPE_FLOAT_t xpos_new, DTYPE_FLOAT_t ypos_new, DTYPE_INT_t guess):
        return 0, 0
    
    cdef get_velocity(self, DTYPE_FLOAT_t time, Particle* particle, 
            DTYPE_FLOAT_t vel[3]):
        """ Return velocity field array for the given space/time coordinates.
        
        """  
        vel[0] = self._get_u_component(particle.xpos)
        vel[1] = self._get_v_component(particle.ypos)
        vel[2] = self._get_w_component(particle.zpos)
        
    cdef get_horizontal_velocity(self, DTYPE_FLOAT_t time, Particle* particle,
            DTYPE_FLOAT_t vel[2]):
        """ Return horizontal velocity for the given space/time coordinates.
        
        """  
        vel[0] = self._get_u_component(particle.xpos)
        vel[1] = self._get_v_component(particle.ypos)

    cdef get_vertical_velocity(self, DTYPE_FLOAT_t time, Particle* particle):
        """ Return vertical velocity field for the given space/time coordinates.
        
        """ 
        return self._get_w_component(particle.zpos)

    def get_velocity_analytic(self, xpos, ypos, zpos=0.0):
        """ Python friendly version of get_velocity(...).
        
        """  
        u = self._get_u_component(xpos)
        v = self._get_v_component(ypos)
        w = self._get_w_component(zpos)
        
        return u,v,w

    def get_position_analytic(self, x0, y0, t):
        """ Return particle positions according to the analytic soln.
        
        """  
        x = self._get_x(x0, t)
        y = self._get_y(y0, t)
        
        return x,y

    def _get_x(self, x0, t):
        return x0 * np.exp(t)
    
    def _get_y(self, y0, t):
        return y0 * np.exp(1.5*t)

    def _get_u_component(self, DTYPE_FLOAT_t xpos):
        return xpos

    def _get_v_component(self, DTYPE_FLOAT_t ypos):
        return 1.5 * ypos

    def _get_w_component(self, DTYPE_FLOAT_t zpos):
        return 0.0

cdef class MockDiffusivityDataReader(DataReader):
    """Test data reader for random displacement models.
    
    Typically these use the vertical or horizontal eddy diffusivity to compute
    particle displacements. This data reader returns vertical diffusivities
    drawn from the analytic profile:

    k = 0.001 + 0.0136245*zpos - 0.00263245*zpos**2 + 2.11875e-4 * zpos**3 - \
        8.65898e-6 * zpos**4 + 1.7623e-7 * zpos**5 - 1.40918e-9 * zpos**6    
    
    where k (m^2/s) is the vertical eddy diffusivity and zpos (m) is the height
    above the sea bed (positivite up). See Visser (1997) and Ross and 
    Sharples (2004).
    
    References:
    -----------
    Visser, A. Using random walk models to simulate the vertical distribution of
    particles in a turbulent water column Marine Ecology Progress Series, 1997,
    158, 275-281
    
    Ross, O. & Sharples, J. Recipe for 1-D Lagrangian particle tracking models 
    in space-varying diffusivity Limnology and Oceanography Methods, 2004, 2, 
    289-302
    
    """
    cdef DTYPE_FLOAT_t _zmin
    cdef DTYPE_FLOAT_t _zmax
    
    def __init__(self):
        self._zmin = 0.0
        self._zmax = 40.0

    cdef DTYPE_FLOAT_t get_zmin(self, DTYPE_FLOAT_t time, Particle *particle):
        return self._zmin

    cdef DTYPE_FLOAT_t get_zmax(self, DTYPE_FLOAT_t time, Particle *particle):
        return self._zmax

    cpdef find_host(self, DTYPE_FLOAT_t xpos_old, DTYPE_FLOAT_t ypos_old,
            DTYPE_FLOAT_t xpos_new, DTYPE_FLOAT_t ypos_new, DTYPE_INT_t guess):
        return 0, 0
    
    cdef get_velocity(self, DTYPE_FLOAT_t time, Particle* particle,
            DTYPE_FLOAT_t vel[3]):
        """ Returns a zeroed velocity vector.
        
        The advective velocity is used by random displacement models adapted to
        work in non-homogenous diffusivity fields.
        """         
        vel[0] = 0.0
        vel[1] = 0.0
        vel[2] = 0.0

    cdef DTYPE_FLOAT_t get_vertical_eddy_diffusivity(self, DTYPE_FLOAT_t time, 
            Particle* particle) except FLOAT_ERR:
        """ Returns the vertical eddy diffusivity at zpos.
        
        """  
        return self._get_vertical_eddy_diffusivity(particle.zpos)

    def _get_vertical_eddy_diffusivity(self, DTYPE_FLOAT_t zpos):
        cdef DTYPE_FLOAT_t k
        k = 0.001 + 0.0136245*zpos - 0.00263245*zpos**2 + 2.11875e-4 * zpos**3 - \
                8.65898e-6 * zpos**4 + 1.7623e-7 * zpos**5 - 1.40918e-9 * zpos**6
        return k

    cdef DTYPE_FLOAT_t get_vertical_eddy_diffusivity_derivative(self, 
            DTYPE_FLOAT_t time, Particle* particle) except FLOAT_ERR:
        """ Returns the derivative of the vertical eddy diffusivity.

        This is approximated numerically, as in PyLag, as opposed to being
        computed directly using the derivative of k.
        """
        return self._get_vertical_eddy_diffusivity_derivative(particle.zpos)
    
    def _get_vertical_eddy_diffusivity_derivative(self, DTYPE_FLOAT_t zpos):
        cdef DTYPE_FLOAT_t zpos_increment, zpos_incremented
        cdef k1, k2

        zpos_increment = (self._zmax - self._zmin) / 1000.0
        
        # Use the negative of zpos_increment at the top of the water column
        if ((zpos + zpos_increment) > self._zmax):
            z_increment = -zpos_increment
        
        zpos_incremented = zpos + zpos_increment

        k1 = self._get_vertical_eddy_diffusivity(zpos)
        k2 = self._get_vertical_eddy_diffusivity(zpos_incremented)
        
        return (k2 - k1) / zpos_increment

cdef class MockRK4Integrator:
    """ Test class for Fourth Order Runga Kutta numerical integration schemes
    
    Parameters:
    -----------
    config : SafeConfigParser
        Configuration object.
    """
    cdef NumIntegrator _num_integrator
    
    def __init__(self, config):
        
        self._num_integrator = get_num_integrator(config)
    
    def advect(self, data_reader, time, xpos, ypos, zpos):
        cdef Particle particle
        cdef Delta delta_X

        # Set these properties to default values
        particle.group_id = 0
        particle.host_horizontal_elem = 0
        particle.k_layer = 0
        particle.in_domain = True

        # Initialise remaining particle properties using the supplied arguments
        particle.xpos = xpos
        particle.ypos = ypos
        particle.zpos = zpos
        
        # Reset Delta object
        reset(&delta_X)
        
        # Advect the particle
        self._num_integrator.advect(time, &particle, data_reader, &delta_X)
        
        # Used Delta values to update the particle's position
        xpos_new = particle.xpos + delta_X.x
        ypos_new = particle.ypos + delta_X.y
        zpos_new = particle.zpos + delta_X.z

        # Return the updated position
        return xpos_new, ypos_new, zpos_new

cdef class MockVerticalLSM:
    """ Test class for vertical lagrangian stochastic models.
    
    Parameters:
    -----------
    config : SafeConfigParser
        Configuration object.
    """
    cdef VerticalLSM _vertical_lsm
    cdef VertBoundaryConditionCalculator _vert_bc_calculator
    
    def __init__(self, config):

        self._vertical_lsm = get_vertical_lsm(config)

        self._vert_bc_calculator = get_vert_boundary_condition_calculator(config)
    
    def apply(self, DataReader data_reader, DTYPE_FLOAT_t time, 
            DTYPE_FLOAT_t xpos, DTYPE_FLOAT_t ypos, zpos_arr, DTYPE_INT_t host):
        cdef Particle particle
        cdef Delta delta_X
        
        cdef DTYPE_FLOAT_t zpos_new, zmin, zmax
        
        cdef DTYPE_INT_t i, n_zpos

        # Set default particle properties
        particle.in_domain = True
        particle.group_id = 0

        # Use supplied args to set the host, x and y positions
        particle.host_horizontal_elem = host
        particle.xpos = xpos
        particle.ypos = ypos

        # Number of z positions
        n_zpos = len(zpos_arr)
        
        # Array in which to store updated z positions
        zpos_new_arr = np.empty(n_zpos, dtype=DTYPE_FLOAT)
        
        # Loop over the particle set
        for i in xrange(n_zpos):
            # Set zpos, local coordinates and variables that define the location
            # of the particle within the vertical grid
            particle.zpos = zpos_arr[i]
            data_reader.set_local_coordinates(&particle)
            data_reader.set_vertical_grid_vars(time, &particle)

            # Reset Delta object
            reset(&delta_X)

            # Apply the vertical lagrangian stochastic model
            self._vertical_lsm.apply(time, &particle, data_reader, &delta_X)

            # Use Delta values to update the particle's position
            zpos_new = particle.zpos + delta_X.z
            
            # Apply boundary conditions
            zmin = data_reader.get_zmin(time, &particle)
            zmax = data_reader.get_zmax(time, &particle)
            if zpos_new < zmin or zpos_new > zmax:
                zpos_new = self._vert_bc_calculator.apply(zpos_new, zmin, zmax)
            
            # Set new z position
            zpos_new_arr[i] = zpos_new 

        # Return the updated position
        return zpos_new_arr