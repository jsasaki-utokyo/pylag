include "constants.pxi"

import numpy as np
from netCDF4 import MFDataset, Dataset, num2date
import glob
import natsort
import datetime
import logging
import ConfigParser

# Cython imports
cimport numpy as np
np.import_array()

# Data types used for constructing C data structures
from data_types_python import DTYPE_INT, DTYPE_FLOAT
from data_types_cython cimport DTYPE_INT_t, DTYPE_FLOAT_t
from cpython cimport bool

from data_reader cimport DataReader

cimport interpolation as interp

from math cimport int_min, float_min

cdef class FVCOMDataReader(DataReader):
    # Configurtion object
    cdef object config

    # Mediator for accessing FVCOM model data read in from file
    cdef object mediator
    
    # Grid dimensions
    cdef DTYPE_INT_t _n_elems, _n_nodes, _n_siglay, _n_siglev
    
    # Element connectivity
    cdef DTYPE_INT_t[:,:] _nv
    
    # Element adjacency
    cdef DTYPE_INT_t[:,:] _nbe
    
    # Nodal coordinates
    cdef DTYPE_FLOAT_t[:] _x
    cdef DTYPE_FLOAT_t[:] _y

    # Element centre coordinates
    cdef DTYPE_FLOAT_t[:] _xc
    cdef DTYPE_FLOAT_t[:] _yc
    
    # Interpolation coefficients
    cdef DTYPE_FLOAT_t[:,:] _a1u
    cdef DTYPE_FLOAT_t[:,:] _a2u
    
    # Sigma layers and levels
    cdef DTYPE_FLOAT_t[:,:] _siglev
    cdef DTYPE_FLOAT_t[:,:] _siglay
    
    # Bathymetry
    cdef DTYPE_FLOAT_t[:] _h
    
    # Sea surface elevation
    cdef DTYPE_FLOAT_t[:] _zeta_last
    cdef DTYPE_FLOAT_t[:] _zeta_next
    
    # u/v/w velocity components
    cdef DTYPE_FLOAT_t[:,:] _u_last
    cdef DTYPE_FLOAT_t[:,:] _u_next
    cdef DTYPE_FLOAT_t[:,:] _v_last
    cdef DTYPE_FLOAT_t[:,:] _v_next
    cdef DTYPE_FLOAT_t[:,:] _omega_last
    cdef DTYPE_FLOAT_t[:,:] _omega_next
    
    # Vertical eddy diffusivities
    cdef DTYPE_FLOAT_t[:,:] _kh_last
    cdef DTYPE_FLOAT_t[:,:] _kh_next
    
    # Horizontal eddy diffusivities
    cdef DTYPE_FLOAT_t[:,:] _viscofh_last
    cdef DTYPE_FLOAT_t[:,:] _viscofh_next
    
    # Time array
    cdef DTYPE_FLOAT_t _time_last
    cdef DTYPE_FLOAT_t _time_next

    def __init__(self, config, mediator):
        self.config = config
        self.mediator = mediator

        self._read_grid()

    cpdef setup_data_access(self, start_datetime, end_datetime):
        self.mediator.setup_data_access(start_datetime, end_datetime)

        self._read_time_dependent_vars()

    cpdef read_data(self, DTYPE_FLOAT_t time):
        """ Update local time dependent variables as required.
        
        """
        time_fraction = interp.get_linear_fraction(time, self._time_last, self._time_next)
        if time_fraction < 0.0 or time_fraction >= 1.0:
            self.mediator.update_reading_frames(time)
            self._read_time_dependent_vars()

    cpdef find_host(self, DTYPE_FLOAT_t xpos, DTYPE_FLOAT_t ypos, DTYPE_INT_t guess):
        return self.find_host_using_local_search(xpos, ypos, guess)

    cpdef find_host_using_local_search(self, DTYPE_FLOAT_t xpos, DTYPE_FLOAT_t ypos, DTYPE_INT_t guess):
        """
        Try to establish the host horizontal element for the particle.
        The algorithm adopted is as described in Shadden (2009), adapted for
        FVCOM's grid which is unstructured in the horizontal only.
        
        Parameters:
        -----------
        particle: Particle
        
        Returns:
        --------
        N/A
        
        Author(s):
        ----------------
        James Clark (PML) October 2015.
            Implemented algorithm based on Shadden (2009).
        
        References:
        -----------
        Shadden, S. 2009 TODO
        """
        # Intermediate arrays/variables
        cdef DTYPE_FLOAT_t phi[N_VERTICES]
        cdef DTYPE_FLOAT_t phi_test

        cdef bool host_found

        cdef DTYPE_INT_t n_host_land_boundaries

        host_found = False
        
        while True:
            # Barycentric coordinates
            self._get_phi(xpos, ypos, guess, phi)

            # Check to see if the particle is in the current element
            phi_test = float_min(float_min(phi[0], phi[1]), phi[2])
            if phi_test >= 0.0:
                host_found = True
            elif phi_test >= -EPSILON:
                if self.config.getboolean('GENERAL', 'full_logging'):
                    logger = logging.getLogger(__name__)
                    logger.warning('EPSILON applied during local host element search.')
                host_found = True
            
            # If the particle has walked into an element with two land
            # boundaries flag it as having moved outside of the domain - ideally
            # unstructured grids should not include such elements.
            if host_found is True:
                n_land_boundaries = 0
                for i in xrange(3):
                    if self._nbe[i,guess] == -1:
                        n_land_boundaries += 1
                
                if n_host_land_boundaries < 2:
                    return guess
                else:
                    if self.config.getboolean('GENERAL', 'full_logging'):
                        logger = logging.getLogger(__name__)
                        logger.warning('Particle prevented from entering '\
                            'element {} which has two land '\
                            'boundaries.'.format(guess))    
                    return -1

            # If not, use phi to select the next element to be searched
            if phi[0] == phi_test:
                guess = self._nbe[0,guess]
            elif phi[1] == phi_test:
                guess = self._nbe[1,guess]
            elif phi[2] == phi_test:
                guess = self._nbe[2,guess]
            else:
                raise RuntimeError('Host element search algorithm failed.')

            if guess == -1:
                # Local search failed
                return guess

    cpdef find_host_using_global_search(self, DTYPE_FLOAT_t xpos, DTYPE_FLOAT_t ypos):
        # Loop counter
        cdef int i

        # Intermediate arrays/variables
        cdef DTYPE_FLOAT_t phi[N_VERTICES]
        cdef DTYPE_FLOAT_t phi_test
        
        for i in xrange(self._n_elems):
            # Barycentric coordinates
            self._get_phi(xpos, ypos, i, phi)

            # Check to see if the particle is in the current element
            phi_test = float_min(float_min(phi[0], phi[1]), phi[2])
            if phi_test >= 0.0:
                return i
            elif phi_test >= -EPSILON:
                if self.config.getboolean('GENERAL', 'full_logging'):
                    logger = logging.getLogger(__name__)
                    logger.warning('EPSILON applied during global host element search.')
                return i
        return -1

    cpdef get_bathymetry(self, DTYPE_FLOAT_t xpos, DTYPE_FLOAT_t ypos, DTYPE_INT_t host):
        """
        Return bathymetry at the supplied x/y coordinates.
        """
        cdef int i # Loop counters
        cdef int vertex # Vertex identifier  
        cdef DTYPE_FLOAT_t phi[N_VERTICES] # Barycentric coordinates 
        cdef DTYPE_FLOAT_t h_tri[N_VERTICES] # Bathymetry at nodes
        cdef DTYPE_FLOAT_t h # Bathymetry at (xpos, ypos)

        # Barycentric coordinates
        self._get_phi(xpos, ypos, host, phi)

        for i in xrange(N_VERTICES):
            vertex = self._nv[i,host]
            h_tri[i] = self._h[vertex]

        h = interp.interpolate_within_element(h_tri, phi)

        return h
    
    cpdef get_sea_sur_elev(self, DTYPE_FLOAT_t time, DTYPE_FLOAT_t xpos,
            DTYPE_FLOAT_t ypos, DTYPE_INT_t host):
        """
        Return sea surface elevation at the supplied x/y coordinates.
        """
        cdef int i # Loop counters
        cdef int vertex # Vertex identifier
        cdef DTYPE_FLOAT_t zeta # Sea surface elevation at (t, xpos, ypos)

        # Intermediate arrays
        cdef DTYPE_FLOAT_t zeta_tri_t_last[N_VERTICES]
        cdef DTYPE_FLOAT_t zeta_tri_t_next[N_VERTICES]
        cdef DTYPE_FLOAT_t zeta_tri[N_VERTICES]
        cdef DTYPE_FLOAT_t phi[N_VERTICES]

        # Barycentric coordinates
        self._get_phi(xpos, ypos, host, phi)

        for i in xrange(N_VERTICES):
            vertex = self._nv[i,host]
            zeta_tri_t_last[i] = self._zeta_last[vertex]
            zeta_tri_t_next[i] = self._zeta_next[vertex]

        # Interpolate in time
        time_fraction = interp.get_linear_fraction(time, self._time_last, self._time_next)
        for i in xrange(N_VERTICES):
            zeta_tri[i] = interp.linear_interp(time_fraction, zeta_tri_t_last[i], zeta_tri_t_next[i])

        # Interpolate in space
        zeta = interp.interpolate_within_element(zeta_tri, phi)

        return zeta

    cdef get_velocity(self, DTYPE_FLOAT_t time, DTYPE_FLOAT_t xpos, 
            DTYPE_FLOAT_t ypos, DTYPE_FLOAT_t zpos, DTYPE_INT_t host,
            DTYPE_FLOAT_t vel[3]):
        """
        Returns the velocity field u(t,x,y,z) through linear interpolation for a 
        particle residing in the horizontal host element `host'. The actual 
        computation is split into two separate parts - one for computing u and 
        v, and one for computing omega. This reflects the fact that u and v are
        defined are element centres on sigma layers, while omega is defined at
        element nodes on sigma levels, which means the two must be handled
        separately.
        """
        # Barycentric coordinates
        cdef DTYPE_FLOAT_t phi[N_VERTICES]
        
        # u/v velocity array
        cdef DTYPE_FLOAT_t vel_uv[2]
        
        cdef DTYPE_INT_t i

        # Barycentric coordinates - precomputed here as required for both u/v 
        # and omega computations
        self._get_phi(xpos, ypos, host, phi)
        
        # Compute u/v velocities and save
        self._get_uv_velocity_using_linear_least_squares_interpolation(time, 
                xpos, ypos, zpos, host, phi, vel_uv)
        for i in xrange(2):
            vel[i] = vel_uv[i]
        
        # Compute omega velocity and save
        vel[2] = self._get_omega_velocity(time, xpos, ypos, zpos, host, phi)
        return

    cdef get_horizontal_velocity(self, DTYPE_FLOAT_t time, DTYPE_FLOAT_t xpos, 
            DTYPE_FLOAT_t ypos, DTYPE_FLOAT_t zpos, DTYPE_INT_t host, 
            DTYPE_FLOAT_t vel[2]):
        # Barycentric coordinates
        cdef DTYPE_FLOAT_t phi[N_VERTICES]

        self._get_phi(xpos, ypos, host, phi)        
        self._get_uv_velocity_using_linear_least_squares_interpolation(time, 
                xpos, ypos, zpos, host, phi, vel)
        return
    
    cdef get_vertical_velocity(self, DTYPE_FLOAT_t time, DTYPE_FLOAT_t xpos, 
            DTYPE_FLOAT_t ypos, DTYPE_FLOAT_t zpos, DTYPE_INT_t host):
        # Barycentric coordinates
        cdef DTYPE_FLOAT_t phi[N_VERTICES]

        self._get_phi(xpos, ypos, host, phi)
        return self._get_omega_velocity(time, xpos, ypos, zpos, host, phi)

    cpdef get_horizontal_eddy_diffusivity(self, DTYPE_FLOAT_t time, DTYPE_FLOAT_t xpos,
            DTYPE_FLOAT_t ypos, DTYPE_FLOAT_t zpos, DTYPE_INT_t host):
        """
        Returns the horizontal eddy diffusivity fiscofh(t,x,y,z) through linear
        interpolation. viscofh is defined at element nodes on sigma layers.
        Above and below the top and bottom sigma layers respectivey viscofh is
        extrapolated, taking a value equal to that on the layer. Linear
        interpolation in the vertical is used for z positions lying between the
        top and bottom sigma layers.
        
        TODO
        - Create tests.
        - Minimise code duplication?
        """
        # Barycentric coordinates
        cdef DTYPE_FLOAT_t phi[N_VERTICES]

        # Variables used when determining indices for the sigma layers that
        # bound the particle's position
        cdef bool particle_found
        cdef bool particle_at_surface_or_bottom_boundary
        cdef DTYPE_FLOAT_t sigma_test
        cdef DTYPE_FLOAT_t sigma_lower_layer, sigma_upper_layer
        cdef DTYPE_INT_t k_boundary, k_lower_layer, k_upper_layer

        # No. of vertices and a temporary object used for determining variable
        # values at the host element's nodes
        cdef int i # Loop counters
        cdef int vertex # Vertex identifier
        
        # Time and sigma fractions for interpolation in time and sigma        
        cdef DTYPE_FLOAT_t time_fraction, sigma_fraction
        
        # Intermediate arrays - viscofh
        cdef DTYPE_FLOAT_t viscofh_tri_t_last_layer_1[N_VERTICES]
        cdef DTYPE_FLOAT_t viscofh_tri_t_next_layer_1[N_VERTICES]
        cdef DTYPE_FLOAT_t viscofh_tri_t_last_layer_2[N_VERTICES]
        cdef DTYPE_FLOAT_t viscofh_tri_t_next_layer_2[N_VERTICES]
        cdef DTYPE_FLOAT_t viscofh_tri_layer_1[N_VERTICES]
        cdef DTYPE_FLOAT_t viscofh_tri_layer_2[N_VERTICES]     
        
        # Interpolated diffusivities on lower and upper bounding sigma layers
        cdef DTYPE_FLOAT_t viscofh_layer_1
        cdef DTYPE_FLOAT_t viscofh_layer_2

        # Barycentric coordinates
        self._get_phi(xpos, ypos, host, phi)
        
        # Find the sigma layers bounding the particle's position. First check
        # the upper and lower boundaries, then the centre of the water columnun.
        particle_found = False
        particle_at_surface_or_bottom_boundary = False
        
        # Try the top sigma layer
        k = 0
        sigma_test = self._interp_on_sigma_layer(phi, host, k)
        if zpos >= sigma_test:
            particle_at_surface_or_bottom_boundary = True
            k_boundary = k
            
            particle_found = True
        else:
            # ... the bottom sigma layer
            k = self._n_siglay - 1
            sigma_test = self._interp_on_sigma_layer(phi, host, k)
            if zpos <= sigma_test:
                particle_at_surface_or_bottom_boundary = True
                k_boundary = k
                
                particle_found = True
            else:
                # ... search the middle of the water column
                for k in xrange(1, self._n_siglay):
                    sigma_test = self._interp_on_sigma_layer(phi, host, k)
                    if zpos >= sigma_test:
                        k_lower_layer = k
                        k_upper_layer = k - 1

                        sigma_lower_layer = self._interp_on_sigma_layer(phi, host, k_lower_layer)
                        sigma_upper_layer = self._interp_on_sigma_layer(phi, host, k_upper_layer)

                        particle_found = True
                        break
        
        if particle_found is False:
            raise ValueError("Particle zpos (={}) not found!".format(zpos))

        # Time fraction
        time_fraction = interp.get_linear_fraction(time, self._time_last, self._time_next)
        if time_fraction < 0.0 or time_fraction > 1.0:
            if self.config.getboolean('GENERAL', 'full_logging'):
                logger = logging.getLogger(__name__)
                logger.info('Invalid time fraction computed at time {}s.'.format(time))
            raise ValueError('Time out of range.')

        # No vertical interpolation for particles near to the surface or bottom, 
        # i.e. above or below the top or bottom sigma layer depths respectively.
        if particle_at_surface_or_bottom_boundary is True:
            # Extract viscofh near to the boundary
            for i in xrange(N_VERTICES):
                vertex = self._nv[i,host]
                viscofh_tri_t_last_layer_1[i] = self._viscofh_last[k_boundary, vertex]
                viscofh_tri_t_next_layer_1[i] = self._viscofh_next[k_boundary, vertex]

            # Interpolate in time
            for i in xrange(N_VERTICES):
                viscofh_tri_layer_1[i] = interp.linear_interp(time_fraction, 
                                            viscofh_tri_t_last_layer_1[i],
                                            viscofh_tri_t_next_layer_1[i])

            # Interpolate viscofh within the host element
            return interp.interpolate_within_element(viscofh_tri_layer_1, phi)

        else:
            # Extract viscofh on the lower and upper bounding sigma layers
            for i in xrange(N_VERTICES):
                vertex = self._nv[i,host]
                viscofh_tri_t_last_layer_1[i] = self._viscofh_last[k_lower_layer, vertex]
                viscofh_tri_t_next_layer_1[i] = self._viscofh_next[k_lower_layer, vertex]
                viscofh_tri_t_last_layer_2[i] = self._viscofh_last[k_upper_layer, vertex]
                viscofh_tri_t_next_layer_2[i] = self._viscofh_next[k_upper_layer, vertex]

            # Interpolate in time
            for i in xrange(N_VERTICES):
                viscofh_tri_layer_1[i] = interp.linear_interp(time_fraction, 
                                            viscofh_tri_t_last_layer_1[i],
                                            viscofh_tri_t_next_layer_1[i])
                viscofh_tri_layer_2[i] = interp.linear_interp(time_fraction, 
                                            viscofh_tri_t_last_layer_2[i],
                                            viscofh_tri_t_next_layer_2[i])

            # Interpolate viscofh within the host element on the upper and lower
            # bounding sigma layers
            viscofh_layer_1 = interp.interpolate_within_element(viscofh_tri_layer_1, phi)
            viscofh_layer_2 = interp.interpolate_within_element(viscofh_tri_layer_2, phi)

            # Vertical interpolation
            sigma_fraction = interp.get_linear_fraction(zpos, sigma_lower_layer, sigma_upper_layer)
            if sigma_fraction < 0.0 or sigma_fraction > 1.0:
                if self.config.getboolean('GENERAL', 'full_logging'):
                    logger = logging.getLogger(__name__)
                    logger.info('Invalid sigma fraction (={}) computed for a sigma value of {}.'.format(sigma_fraction, zpos))
                raise ValueError('Sigma out of range.')
            return interp.linear_interp(sigma_fraction, viscofh_layer_1, viscofh_layer_2)

    cpdef get_horizontal_eddy_diffusivity_derivative(self, DTYPE_FLOAT_t time,
            DTYPE_FLOAT_t xpos, DTYPE_FLOAT_t ypos, DTYPE_FLOAT_t zpos, 
            DTYPE_INT_t host):
        """
        Returns the spatial derivative of the horizontal eddy diffusivity 
        fiscofh(t,x,y,z) through ...?
        """
        pass

    cpdef get_vertical_eddy_diffusivity(self, DTYPE_FLOAT_t time, DTYPE_FLOAT_t xpos,
            DTYPE_FLOAT_t ypos, DTYPE_FLOAT_t zpos, DTYPE_INT_t host):
        """
        Returns the vertical eddy diffusivity k(t,x,y,z) through linear
        interpolation.
        """
        # Barycentric coordinates
        cdef DTYPE_FLOAT_t phi[N_VERTICES]
        
        # Variables used when determining indices for the sigma levels that
        # bound the particle's position
        cdef DTYPE_INT_t k_lower_level, k_upper_level
        cdef DTYPE_FLOAT_t sigma_lower_level, sigma_upper_level        
        cdef bool particle_found

        # No. of vertices and a temporary object used for determining variable
        # values at the host element's nodes
        cdef int i # Loop counters
        cdef int vertex # Vertex identifier
        
        # Time and sigma fractions for interpolation in time and sigma        
        cdef DTYPE_FLOAT_t time_fraction, sigma_fraction
        
        # Intermediate arrays - kh
        cdef DTYPE_FLOAT_t kh_tri_t_last_lower_level[N_VERTICES]
        cdef DTYPE_FLOAT_t kh_tri_t_next_lower_level[N_VERTICES]
        cdef DTYPE_FLOAT_t kh_tri_t_last_upper_level[N_VERTICES]
        cdef DTYPE_FLOAT_t kh_tri_t_next_upper_level[N_VERTICES]
        cdef DTYPE_FLOAT_t kh_tri_lower_level[N_VERTICES]
        cdef DTYPE_FLOAT_t kh_tri_upper_level[N_VERTICES]
        
        # Intermediate arrays - zeta/h
        cdef DTYPE_FLOAT_t zeta_tri_t_last[N_VERTICES]
        cdef DTYPE_FLOAT_t zeta_tri_t_next[N_VERTICES]
        cdef DTYPE_FLOAT_t zeta_tri[N_VERTICES]
        cdef DTYPE_FLOAT_t h_tri[N_VERTICES]        
        
        # Interpolated diffusivities on lower and upper bounding sigma levels
        cdef DTYPE_FLOAT_t kh_lower_level
        cdef DTYPE_FLOAT_t kh_upper_level

        # Interpolated zeta/h
        cdef DTYPE_FLOAT_t zeta
        cdef DTYPE_FLOAT_t h

        # Compute barycentric coordinates for the given x/y coordinates
        self._get_phi(xpos, ypos, host, phi)

        # Determine upper and lower bounding sigma levels
        particle_found = False
        for i in xrange(self._n_siglay):
            k_lower_level = i + 1
            k_upper_level = i
            sigma_lower_level = self._interp_on_sigma_level(phi, host, k_lower_level)
            sigma_upper_level = self._interp_on_sigma_level(phi, host, k_upper_level)
            
            if zpos <= sigma_upper_level and zpos >= sigma_lower_level:
                particle_found = True
                break
        
        if particle_found is False:
            raise ValueError("Particle zpos (={} not found!".format(zpos))

        # Extract kh on the lower and upper bounding sigma levels, h and zeta
        for i in xrange(N_VERTICES):
            vertex = self._nv[i,host]
            kh_tri_t_last_lower_level[i] = self._kh_last[k_lower_level, vertex]
            kh_tri_t_next_lower_level[i] = self._kh_next[k_lower_level, vertex]
            kh_tri_t_last_upper_level[i] = self._kh_last[k_upper_level, vertex]
            kh_tri_t_next_upper_level[i] = self._kh_next[k_upper_level, vertex]
            zeta_tri_t_last[i] = self._zeta_last[vertex]
            zeta_tri_t_next[i] = self._zeta_next[vertex]
            h_tri[i] = self._h[vertex]

        # Interpolate kh and zeta in time
        time_fraction = interp.get_linear_fraction(time, self._time_last, self._time_next)
        for i in xrange(N_VERTICES):
            kh_tri_lower_level[i] = interp.linear_interp(time_fraction, 
                                                kh_tri_t_last_lower_level[i],
                                                kh_tri_t_next_lower_level[i])
            kh_tri_upper_level[i] = interp.linear_interp(time_fraction, 
                                                kh_tri_t_last_upper_level[i],
                                                kh_tri_t_next_upper_level[i])
            zeta_tri[i] = interp.linear_interp(time_fraction, zeta_tri_t_last[i], zeta_tri_t_next[i])

        # Interpolate kh, zeta and h within the host
        kh_lower_level = interp.interpolate_within_element(kh_tri_lower_level, phi)
        kh_upper_level = interp.interpolate_within_element(kh_tri_upper_level, phi)
        zeta = interp.interpolate_within_element(zeta_tri, phi)
        h = interp.interpolate_within_element(h_tri, phi)

        # Interpolate between sigma levels
        sigma_fraction = interp.get_linear_fraction(zpos, sigma_lower_level, sigma_upper_level)
        if sigma_fraction < 0.0 or sigma_fraction > 1.0:
            if self.config.getboolean('GENERAL', 'full_logging'):
                logger = logging.getLogger(__name__)
                logger.info('Invalid sigma fraction (={}) computed for a sigma value of {}.'.format(sigma_fraction, zpos))
            raise ValueError('Sigma out of range.')
        
        return interp.linear_interp(sigma_fraction, kh_lower_level, kh_upper_level) / (h + zeta)**2

    cpdef get_vertical_eddy_diffusivity_derivative(self, DTYPE_FLOAT_t time,
            DTYPE_FLOAT_t xpos, DTYPE_FLOAT_t ypos, DTYPE_FLOAT_t zpos, 
            DTYPE_INT_t host):
        """
        Return a numerical approximation of the gradient in the vertical eddy 
        diffusivity at (t,x,y,z).
        """
        # Diffusivities
        cdef DTYPE_FLOAT_t kh1, kh2
        
        # Diffusivity gradient
        cdef DTYPE_FLOAT_t k_prime
        
        # Z coordinate vars for the gradient calculation
        cdef DTYPE_FLOAT_t zpos_increment, zpos_incremented
        
        # Use a point arbitrarily close to zpos (in sigma coordinates) for the 
        # gradient calculation
        zpos_increment = 1.0e-3
        
        # Use the negative of zpos_increment at the top of the water column
        if ((zpos + zpos_increment) > 0.0):
            zpos_increment = -zpos_increment
            
        # A point close to zpos
        zpos_incremented = zpos + zpos_increment

        # Compute the gradient
        k1 = self.get_vertical_eddy_diffusivity(time, xpos, ypos, zpos, host)
        k2 = self.get_vertical_eddy_diffusivity(time, xpos, ypos, zpos_incremented, host)
        k_prime = (k2 - k1) / zpos_increment

        return k_prime

    cdef _get_uv_velocity_using_shepard_interpolation(self, DTYPE_FLOAT_t time,
            DTYPE_FLOAT_t xpos, DTYPE_FLOAT_t ypos, DTYPE_FLOAT_t zpos, 
            DTYPE_INT_t host, DTYPE_FLOAT_t phi[N_VERTICES], 
            DTYPE_FLOAT_t vel[2]):
        """Return u and v components at a point using Shepard interpolation.
        
        In FVCOM, the u and v velocity components are defined at element centres
        on sigma layers and saved at discrete points in time. Here,
        u(t,x,y,z) and v(t,x,y,z) are retrieved through i) linear interpolation
        in t and z, and ii) Shepard interpolation (which is basically a 
        special case of normalized radial basis function interpolation)
        in x and y.
        
        In Shepard interpolation, the algorithm uses velocities defined at 
        the host element's centre and its immediate neghbours (i.e. at the
        centre of those elements that share a face with the host element).
        
        TODO - apply boundary fix?
        
        Parameters
        ----------
        TODO
        """
        # x/y coordinates of element centres
        cdef DTYPE_FLOAT_t xc[N_NEIGH_ELEMS]
        cdef DTYPE_FLOAT_t yc[N_NEIGH_ELEMS]

        # Temporary array for vel at element centres at last time point
        cdef DTYPE_FLOAT_t uc_last[N_NEIGH_ELEMS]
        cdef DTYPE_FLOAT_t vc_last[N_NEIGH_ELEMS]

        # Temporary array for vel at element centres at next time point
        cdef DTYPE_FLOAT_t uc_next[N_NEIGH_ELEMS]
        cdef DTYPE_FLOAT_t vc_next[N_NEIGH_ELEMS]

        # Vel at element centres in overlying sigma layer
        cdef DTYPE_FLOAT_t uc1[N_NEIGH_ELEMS]
        cdef DTYPE_FLOAT_t vc1[N_NEIGH_ELEMS]

        # Vel at element centres in underlying sigma layer
        cdef DTYPE_FLOAT_t uc2[N_NEIGH_ELEMS]
        cdef DTYPE_FLOAT_t vc2[N_NEIGH_ELEMS]     
        
        # Vel at the given location in the overlying sigma layer
        cdef DTYPE_FLOAT_t up1, vp1
        
        # Vel at the given location in the underlying sigma layer
        cdef DTYPE_FLOAT_t up2, vp2
        
        cdef DTYPE_FLOAT_t dudx, dudy, dvdx, dvdy
        
        cdef DTYPE_FLOAT_t rx, ry
        
        # Variables used when determining indices for the sigma layers that
        # bound the particle's position
        cdef bool particle_found
        cdef bool particle_at_surface_or_bottom_boundary
        cdef DTYPE_FLOAT_t sigma_test
        cdef DTYPE_FLOAT_t sigma_lower_layer, sigma_upper_layer
        cdef DTYPE_INT_t k_boundary, k_lower_layer, k_upper_layer
        
        # Time and sigma fractions for interpolation in time and sigma
        cdef DTYPE_FLOAT_t time_fraction, sigma_fraction

        # Array and loop indices
        cdef DTYPE_INT_t i, j, k, neighbour
        
        cdef DTYPE_INT_t nbe_min

        # Barycentric coordinates
        self._get_phi(xpos, ypos, host, phi)
        
        # Find the sigma layers bounding the particle's position. First check
        # the upper and lower boundaries, then the centre of the water columnun.
        particle_found = False
        particle_at_surface_or_bottom_boundary = False
        
        # Try the top sigma layer
        k = 0
        sigma_test = self._interp_on_sigma_layer(phi, host, k)
        if zpos >= sigma_test:
            particle_at_surface_or_bottom_boundary = True
            k_boundary = k
            
            particle_found = True
        else:
            # ... the bottom sigma layer
            k = self._n_siglay - 1
            sigma_test = self._interp_on_sigma_layer(phi, host, k)
            if zpos <= sigma_test:
                particle_at_surface_or_bottom_boundary = True
                k_boundary = k
                
                particle_found = True
            else:
                # ... search the middle of the water column
                for k in xrange(1, self._n_siglay):
                    sigma_test = self._interp_on_sigma_layer(phi, host, k)
                    if zpos >= sigma_test:
                        k_lower_layer = k
                        k_upper_layer = k - 1

                        sigma_lower_layer = self._interp_on_sigma_layer(phi, host, k_lower_layer)
                        sigma_upper_layer = self._interp_on_sigma_layer(phi, host, k_upper_layer)

                        particle_found = True
                        break
        
        if particle_found is False:
            raise ValueError("Particle zpos (={} not found!".format(zpos))

        # Time fraction
        time_fraction = interp.get_linear_fraction(time, self._time_last, self._time_next)
        if time_fraction < 0.0 or time_fraction > 1.0:
            if self.config.getboolean('GENERAL', 'full_logging'):
                logger = logging.getLogger(__name__)
                logger.info('Invalid time fraction computed at time {}s.'.format(time))
            raise ValueError('Time out of range.')

        nbe_min = int_min(int_min(self._nbe[0, host], self._nbe[1, host]), self._nbe[2, host])
        if nbe_min < 0:
            # Boundary element - no horizontal interpolation
            if particle_at_surface_or_bottom_boundary is True:
                vel[0] = interp.linear_interp(time_fraction, self._u_last[k_boundary, host], self._u_next[k_boundary, host])
                vel[1] = interp.linear_interp(time_fraction, self._v_last[k_boundary, host], self._v_next[k_boundary, host])
                return
            else:
                up1 = interp.linear_interp(time_fraction, self._u_last[k_lower_layer, host], self._u_next[k_lower_layer, host])
                vp1 = interp.linear_interp(time_fraction, self._v_last[k_lower_layer, host], self._v_next[k_lower_layer, host])
                up2 = interp.linear_interp(time_fraction, self._u_last[k_upper_layer, host], self._u_next[k_upper_layer, host])
                vp2 = interp.linear_interp(time_fraction, self._v_last[k_upper_layer, host], self._v_next[k_upper_layer, host])
        else:
            # Non-boundary element - perform horizontal and temporal interpolation
            if particle_at_surface_or_bottom_boundary is True:
                xc[0] = self._xc[host]
                yc[0] = self._yc[host]
                uc1[0] = interp.linear_interp(time_fraction, self._u_last[k_boundary, host], self._u_next[k_boundary, host])
                vc1[0] = interp.linear_interp(time_fraction, self._v_last[k_boundary, host], self._v_next[k_boundary, host])
                for i in xrange(3):
                    neighbour = self._nbe[i, host]
                    j = i+1 # +1 as host is 0
                    xc[j] = self._xc[neighbour] 
                    yc[j] = self._yc[neighbour]
                    uc1[j] = interp.linear_interp(time_fraction, self._u_last[k_boundary, neighbour], self._u_next[k_boundary, neighbour])
                    vc1[j] = interp.linear_interp(time_fraction, self._v_last[k_boundary, neighbour], self._v_next[k_boundary, neighbour])
                
                vel[0] = self._interpolate_vel_between_elements(xpos, ypos, host, uc1)
                vel[1] = self._interpolate_vel_between_elements(xpos, ypos, host, vc1)
                return  
            else:
                xc[0] = self._xc[host]
                yc[0] = self._yc[host]
                uc1[0] = interp.linear_interp(time_fraction, self._u_last[k_lower_layer, host], self._u_next[k_lower_layer, host])
                vc1[0] = interp.linear_interp(time_fraction, self._v_last[k_lower_layer, host], self._v_next[k_lower_layer, host])
                uc2[0] = interp.linear_interp(time_fraction, self._u_last[k_upper_layer, host], self._u_next[k_upper_layer, host])
                vc2[0] = interp.linear_interp(time_fraction, self._v_last[k_upper_layer, host], self._v_next[k_upper_layer, host])
                for i in xrange(3):
                    neighbour = self._nbe[i, host]
                    j = i+1 # +1 as host is 0
                    xc[j] = self._xc[neighbour] 
                    yc[j] = self._yc[neighbour]
                    uc1[j] = interp.linear_interp(time_fraction, self._u_last[k_lower_layer, host], self._u_next[k_lower_layer, host])
                    vc1[j] = interp.linear_interp(time_fraction, self._v_last[k_lower_layer, host], self._v_next[k_lower_layer, host])    
                    uc2[j] = interp.linear_interp(time_fraction, self._u_last[k_upper_layer, host], self._u_next[k_upper_layer, host])
                    vc2[j] = interp.linear_interp(time_fraction, self._v_last[k_upper_layer, host], self._v_next[k_upper_layer, host])
            
            # ... lower bounding sigma layer
            up1 = self._interpolate_vel_between_elements(xpos, ypos, host, uc1)
            vp1 = self._interpolate_vel_between_elements(xpos, ypos, host, vc1)

            # ... upper bounding sigma layer
            up2 = self._interpolate_vel_between_elements(xpos, ypos, host, uc2)
            vp2 = self._interpolate_vel_between_elements(xpos, ypos, host, vc2)
            
        # Vertical interpolation
        sigma_fraction = interp.get_linear_fraction(zpos, sigma_lower_layer, sigma_upper_layer)
        if sigma_fraction < 0.0 or sigma_fraction > 1.0:
            if self.config.getboolean('GENERAL', 'full_logging'):
                logger = logging.getLogger(__name__)
                logger.info('Invalid sigma fraction (={}) computed for a sigma value of {}.'.format(sigma_fraction, zpos))
            raise ValueError('Sigma out of range.')
        vel[0] = interp.linear_interp(sigma_fraction, up1, up2)
        vel[1] = interp.linear_interp(sigma_fraction, vp1, vp2)
        return

    cdef _get_uv_velocity_using_linear_least_squares_interpolation(self, 
            DTYPE_FLOAT_t time, DTYPE_FLOAT_t xpos, DTYPE_FLOAT_t ypos, 
            DTYPE_FLOAT_t zpos, DTYPE_INT_t host, DTYPE_FLOAT_t phi[N_VERTICES],
            DTYPE_FLOAT_t vel[2]):
        """Return u and v components at a point using LLS interpolation.
        
        In FVCOM, the u and v velocity components are defined at element centres
        on sigma layers and saved at discrete points in time. Here,
        u(t,x,y,z) and v(t,x,y,z) are retrieved through i) linear interpolation
        in t and z, and ii) Linear Least Squares (LLS) Interpolation in x and y.
        
        The LLS interpolation method uses the a1u and a2u interpolants computed
        by FVCOM (see the FVCOM manual) and saved with the model output. An
        exception to this occurs in boundary elements, where the a1u and a2u
        interpolants are set to zero. In these elements, particles "see" the
        same velocity throughout the whole element. This velocity is that which
        is defined at the element's centroid.
        
        This interpolation method can result in particles being pushed towards
        and ultimately over the land boundary.

        Parameters:
        -----------
        TODO
        """
        # x/y coordinates of element centres
        cdef DTYPE_FLOAT_t xc[N_NEIGH_ELEMS]
        cdef DTYPE_FLOAT_t yc[N_NEIGH_ELEMS]

        # Temporary array for vel at element centres at last time point
        cdef DTYPE_FLOAT_t uc_last[N_NEIGH_ELEMS]
        cdef DTYPE_FLOAT_t vc_last[N_NEIGH_ELEMS]

        # Temporary array for vel at element centres at next time point
        cdef DTYPE_FLOAT_t uc_next[N_NEIGH_ELEMS]
        cdef DTYPE_FLOAT_t vc_next[N_NEIGH_ELEMS]

        # Vel at element centres in overlying sigma layer
        cdef DTYPE_FLOAT_t uc1[N_NEIGH_ELEMS]
        cdef DTYPE_FLOAT_t vc1[N_NEIGH_ELEMS]

        # Vel at element centres in underlying sigma layer
        cdef DTYPE_FLOAT_t uc2[N_NEIGH_ELEMS]
        cdef DTYPE_FLOAT_t vc2[N_NEIGH_ELEMS]     
        
        # Vel at the given location in the overlying sigma layer
        cdef DTYPE_FLOAT_t up1, vp1
        
        # Vel at the given location in the underlying sigma layer
        cdef DTYPE_FLOAT_t up2, vp2
        
        cdef DTYPE_FLOAT_t dudx, dudy, dvdx, dvdy
        
        cdef DTYPE_FLOAT_t rx, ry
        
        # Variables used when determining indices for the sigma layers that
        # bound the particle's position
        cdef bool particle_found
        cdef bool particle_at_surface_or_bottom_boundary
        cdef DTYPE_FLOAT_t sigma_test
        cdef DTYPE_FLOAT_t sigma_lower_layer, sigma_upper_layer
        cdef DTYPE_INT_t k_boundary, k_lower_layer, k_upper_layer
        
        # Time and sigma fractions for interpolation in time and sigma
        cdef DTYPE_FLOAT_t time_fraction, sigma_fraction

        # Array and loop indices
        cdef DTYPE_INT_t i, j, k, neighbour
        
        cdef DTYPE_INT_t nbe_min

        # Barycentric coordinates
        self._get_phi(xpos, ypos, host, phi)
        
        # Find the sigma layers bounding the particle's position. First check
        # the upper and lower boundaries, then the centre of the water columnun.
        particle_found = False
        particle_at_surface_or_bottom_boundary = False
        
        # Try the top sigma layer
        k = 0
        sigma_test = self._interp_on_sigma_layer(phi, host, k)
        if zpos >= sigma_test:
            particle_at_surface_or_bottom_boundary = True
            k_boundary = k
            
            particle_found = True
        else:
            # ... the bottom sigma layer
            k = self._n_siglay - 1
            sigma_test = self._interp_on_sigma_layer(phi, host, k)
            if zpos <= sigma_test:
                particle_at_surface_or_bottom_boundary = True
                k_boundary = k
                
                particle_found = True
            else:
                # ... search the middle of the water column
                for k in xrange(1, self._n_siglay):
                    sigma_test = self._interp_on_sigma_layer(phi, host, k)
                    if zpos >= sigma_test:
                        k_lower_layer = k
                        k_upper_layer = k - 1

                        sigma_lower_layer = self._interp_on_sigma_layer(phi, host, k_lower_layer)
                        sigma_upper_layer = self._interp_on_sigma_layer(phi, host, k_upper_layer)

                        particle_found = True
                        break
        
        if particle_found is False:
            raise ValueError("Particle zpos (={} not found!".format(zpos))

        # Time fraction
        time_fraction = interp.get_linear_fraction(time, self._time_last, self._time_next)
        if time_fraction < 0.0 or time_fraction > 1.0:
            if self.config.getboolean('GENERAL', 'full_logging'):
                logger = logging.getLogger(__name__)
                logger.info('Invalid time fraction computed at time {}s.'.format(time))
            raise ValueError('Time out of range.')

        nbe_min = int_min(int_min(self._nbe[0, host], self._nbe[1, host]), self._nbe[2, host])
        if nbe_min < 0:
            # Boundary element - no horizontal interpolation
            if particle_at_surface_or_bottom_boundary is True:
                vel[0] = interp.linear_interp(time_fraction, self._u_last[k_boundary, host], self._u_next[k_boundary, host])
                vel[1] = interp.linear_interp(time_fraction, self._v_last[k_boundary, host], self._v_next[k_boundary, host])
                return
            else:
                up1 = interp.linear_interp(time_fraction, self._u_last[k_lower_layer, host], self._u_next[k_lower_layer, host])
                vp1 = interp.linear_interp(time_fraction, self._v_last[k_lower_layer, host], self._v_next[k_lower_layer, host])
                up2 = interp.linear_interp(time_fraction, self._u_last[k_upper_layer, host], self._u_next[k_upper_layer, host])
                vp2 = interp.linear_interp(time_fraction, self._v_last[k_upper_layer, host], self._v_next[k_upper_layer, host])
        else:
            # Non-boundary element - perform horizontal and temporal interpolation
            if particle_at_surface_or_bottom_boundary is True:
                xc[0] = self._xc[host]
                yc[0] = self._yc[host]
                uc1[0] = interp.linear_interp(time_fraction, self._u_last[k_boundary, host], self._u_next[k_boundary, host])
                vc1[0] = interp.linear_interp(time_fraction, self._v_last[k_boundary, host], self._v_next[k_boundary, host])
                for i in xrange(3):
                    neighbour = self._nbe[i, host]
                    j = i+1 # +1 as host is 0
                    xc[j] = self._xc[neighbour] 
                    yc[j] = self._yc[neighbour]
                    uc1[j] = interp.linear_interp(time_fraction, self._u_last[k_boundary, neighbour], self._u_next[k_boundary, neighbour])
                    vc1[j] = interp.linear_interp(time_fraction, self._v_last[k_boundary, neighbour], self._v_next[k_boundary, neighbour])
                
                vel[0] = self._interpolate_vel_between_elements(xpos, ypos, host, uc1)
                vel[1] = self._interpolate_vel_between_elements(xpos, ypos, host, vc1)
                return  
            else:
                xc[0] = self._xc[host]
                yc[0] = self._yc[host]
                uc1[0] = interp.linear_interp(time_fraction, self._u_last[k_lower_layer, host], self._u_next[k_lower_layer, host])
                vc1[0] = interp.linear_interp(time_fraction, self._v_last[k_lower_layer, host], self._v_next[k_lower_layer, host])
                uc2[0] = interp.linear_interp(time_fraction, self._u_last[k_upper_layer, host], self._u_next[k_upper_layer, host])
                vc2[0] = interp.linear_interp(time_fraction, self._v_last[k_upper_layer, host], self._v_next[k_upper_layer, host])
                for i in xrange(3):
                    neighbour = self._nbe[i, host]
                    j = i+1 # +1 as host is 0
                    xc[j] = self._xc[neighbour] 
                    yc[j] = self._yc[neighbour]
                    uc1[j] = interp.linear_interp(time_fraction, self._u_last[k_lower_layer, host], self._u_next[k_lower_layer, host])
                    vc1[j] = interp.linear_interp(time_fraction, self._v_last[k_lower_layer, host], self._v_next[k_lower_layer, host])    
                    uc2[j] = interp.linear_interp(time_fraction, self._u_last[k_upper_layer, host], self._u_next[k_upper_layer, host])
                    vc2[j] = interp.linear_interp(time_fraction, self._v_last[k_upper_layer, host], self._v_next[k_upper_layer, host])
            
            # ... lower bounding sigma layer
            up1 = self._interpolate_vel_between_elements(xpos, ypos, host, uc1)
            vp1 = self._interpolate_vel_between_elements(xpos, ypos, host, vc1)

            # ... upper bounding sigma layer
            up2 = self._interpolate_vel_between_elements(xpos, ypos, host, uc2)
            vp2 = self._interpolate_vel_between_elements(xpos, ypos, host, vc2)
            
        # Vertical interpolation
        sigma_fraction = interp.get_linear_fraction(zpos, sigma_lower_layer, sigma_upper_layer)
        if sigma_fraction < 0.0 or sigma_fraction > 1.0:
            if self.config.getboolean('GENERAL', 'full_logging'):
                logger = logging.getLogger(__name__)
                logger.info('Invalid sigma fraction (={}) computed for a sigma value of {}.'.format(sigma_fraction, zpos))
            raise ValueError('Sigma out of range.')
        vel[0] = interp.linear_interp(sigma_fraction, up1, up2)
        vel[1] = interp.linear_interp(sigma_fraction, vp1, vp2)
        return

    cdef _get_omega_velocity(self, DTYPE_FLOAT_t time, DTYPE_FLOAT_t xpos, 
            DTYPE_FLOAT_t ypos, DTYPE_FLOAT_t zpos, DTYPE_INT_t host, 
            DTYPE_FLOAT_t phi[N_VERTICES]):
        """
        Steps:
        1) Determine natural coordinates of the host element - these are used
        in the computation of sigma on the upper and lower sigma
        levels bounding the particle's position.
        2) Determine indices for the upper and lower sigma levels
        bounding the particle's position.
        3) Determine the value of sigma on the upper and lower sigma
        levels bounding the particle's position.
        4) Calculate the time fraction used for interpolation in time.
        6) Perform time interpolation of omega at nodes of the host element on
        the upper and lower bounding sigma levels.
        8) Interpolate omega within the host element on the upper and lower 
        bounding sigma levels.
        10) Perform vertical interpolation of omega between sigma levels at the
        particle's x/y position.
        """
        # Variables used when determining indices for the sigma levels that
        # bound the particle's position
        cdef DTYPE_INT_t k_lower_level, k_upper_level
        cdef DTYPE_FLOAT_t sigma_lower_level, sigma_upper_level        
        cdef bool particle_found

        # No. of vertices and a temporary object used for determining variable
        # values at the host element's nodes
        cdef int i # Loop counters
        cdef int vertex # Vertex identifier
        
        # Time and sigma fractions for interpolation in time and sigma        
        cdef DTYPE_FLOAT_t time_fraction, sigma_fraction
        
        # Intermediate arrays - omega
        cdef DTYPE_FLOAT_t omega_tri_t_last_lower_level[N_VERTICES]
        cdef DTYPE_FLOAT_t omega_tri_t_next_lower_level[N_VERTICES]
        cdef DTYPE_FLOAT_t omega_tri_t_last_upper_level[N_VERTICES]
        cdef DTYPE_FLOAT_t omega_tri_t_next_upper_level[N_VERTICES]
        cdef DTYPE_FLOAT_t omega_tri_lower_level[N_VERTICES]
        cdef DTYPE_FLOAT_t omega_tri_upper_level[N_VERTICES]
        
        # Intermediate arrays - zeta/h
        cdef DTYPE_FLOAT_t zeta_tri_t_last[N_VERTICES]
        cdef DTYPE_FLOAT_t zeta_tri_t_next[N_VERTICES]
        cdef DTYPE_FLOAT_t zeta_tri[N_VERTICES]
        cdef DTYPE_FLOAT_t h_tri[N_VERTICES]        
        
        # Interpolated omegas on lower and upper bounding sigma levels
        cdef DTYPE_FLOAT_t omega_lower_level
        cdef DTYPE_FLOAT_t omega_upper_level

        # Interpolated zeta/h
        cdef DTYPE_FLOAT_t zeta
        cdef DTYPE_FLOAT_t h

        # Determine upper and lower bounding sigma levels
        particle_found = False
        for i in xrange(self._n_siglay):
            k_lower_level = i + 1
            k_upper_level = i
            sigma_lower_level = self._interp_on_sigma_level(phi, host, k_lower_level)
            sigma_upper_level = self._interp_on_sigma_level(phi, host, k_upper_level)
            
            if zpos <= sigma_upper_level and zpos >= sigma_lower_level:
                particle_found = True
                break
        
        if particle_found is False:
            raise ValueError("Particle zpos (={} not found!".format(zpos))

        # Extract omega on the lower and upper bounding sigma levels, h and zeta
        for i in xrange(N_VERTICES):
            vertex = self._nv[i,host]
            omega_tri_t_last_lower_level[i] = self._omega_last[k_lower_level, vertex]
            omega_tri_t_next_lower_level[i] = self._omega_next[k_lower_level, vertex]
            omega_tri_t_last_upper_level[i] = self._omega_last[k_upper_level, vertex]
            omega_tri_t_next_upper_level[i] = self._omega_next[k_upper_level, vertex]
            zeta_tri_t_last[i] = self._zeta_last[vertex]
            zeta_tri_t_next[i] = self._zeta_next[vertex]
            h_tri[i] = self._h[vertex]

        # Interpolate omega and zeta in time
        time_fraction = interp.get_linear_fraction(time, self._time_last, self._time_next)
        for i in xrange(N_VERTICES):
            omega_tri_lower_level[i] = interp.linear_interp(time_fraction, 
                                                omega_tri_t_last_lower_level[i],
                                                omega_tri_t_next_lower_level[i])
            omega_tri_upper_level[i] = interp.linear_interp(time_fraction, 
                                                omega_tri_t_last_upper_level[i],
                                                omega_tri_t_next_upper_level[i])
            zeta_tri[i] = interp.linear_interp(time_fraction, zeta_tri_t_last[i], zeta_tri_t_next[i])

        # Interpolate omega, zeta and h within the host
        omega_lower_level = interp.interpolate_within_element(omega_tri_lower_level, phi)
        omega_upper_level = interp.interpolate_within_element(omega_tri_upper_level, phi)
        zeta = interp.interpolate_within_element(zeta_tri, phi)
        h = interp.interpolate_within_element(h_tri, phi)

        # Interpolate between sigma levels
        sigma_fraction = interp.get_linear_fraction(zpos, sigma_lower_level, sigma_upper_level)
        if sigma_fraction < 0.0 or sigma_fraction > 1.0:
            if self.config.getboolean('GENERAL', 'full_logging'):
                logger = logging.getLogger(__name__)
                logger.info('Invalid sigma fraction (={}) computed for a sigma value of {}.'.format(sigma_fraction, zpos))
            raise ValueError('Sigma out of range.')
        return interp.linear_interp(sigma_fraction, omega_lower_level, omega_upper_level) / (h + zeta)

    def _read_grid(self):
        """ Set grid and coordinate variables.
        
        All communications go via the mediator in order to guarentee support for
        both serial and parallel simulations.
        """
        # Read in the grid's dimensions
        self._n_nodes = self.mediator.get_dimension_variable('node')
        self._n_elems = self.mediator.get_dimension_variable('nele')
        self._n_siglev = self.mediator.get_dimension_variable('siglev')
        self._n_siglay = self.mediator.get_dimension_variable('siglay')
        
        # Grid connectivity/adjacency
        self._nv = self.mediator.get_grid_variable('nv', (3, self._n_elems), DTYPE_INT)
        self._nbe = self.mediator.get_grid_variable('nbe', (3, self._n_elems), DTYPE_INT)

        # Cartesian coordinates
        self._x = self.mediator.get_grid_variable('x', (self._n_nodes), DTYPE_FLOAT)
        self._y = self.mediator.get_grid_variable('y', (self._n_nodes), DTYPE_FLOAT)
        self._xc = self.mediator.get_grid_variable('xc', (self._n_elems), DTYPE_FLOAT)
        self._yc = self.mediator.get_grid_variable('yc', (self._n_elems), DTYPE_FLOAT)

        # Sigma levels at nodal coordinates
        self._siglev = self.mediator.get_grid_variable('siglev', (self._n_siglev, self._n_nodes), DTYPE_FLOAT)
        
        # Sigma layers at nodal coordinates
        self._siglay = self.mediator.get_grid_variable('siglay', (self._n_siglay, self._n_nodes), DTYPE_FLOAT)

        # Bathymetry
        self._h = self.mediator.get_grid_variable('h', (self._n_nodes), DTYPE_FLOAT)

        # Interpolation parameters (a1u, a2u, aw0, awx, awy)
        self._a1u = self.mediator.get_grid_variable('a1u', (4, self._n_elems), DTYPE_FLOAT)
        self._a2u = self.mediator.get_grid_variable('a2u', (4, self._n_elems), DTYPE_FLOAT)

    cdef _read_time_dependent_vars(self):
        """ Set time references and update memory views for FVCOM data fields.
        
        For each FVCOM time-dependent variable needed by PyLag two references
        are stored. These correspond to the last and next time points at which
        FVCOM data was saved. Together these bound PyLag's current time point.
        
        All communications go via the mediator in order to guarentee support for
        both serial and parallel simulations.
        """
        # Update time references
        self._time_last = self.mediator.get_time_at_last_time_index()
        self._time_next = self.mediator.get_time_at_next_time_index()
        
        # Update memory views for zeta
        self._zeta_last = self.mediator.get_time_dependent_variable_at_last_time_index('zeta', (self._n_nodes), DTYPE_FLOAT)
        self._zeta_next = self.mediator.get_time_dependent_variable_at_next_time_index('zeta', (self._n_nodes), DTYPE_FLOAT)
        
        # Update memory views for u, v and w
        self._u_last = self.mediator.get_time_dependent_variable_at_last_time_index('u', (self._n_siglay, self._n_elems), DTYPE_FLOAT)
        self._u_next = self.mediator.get_time_dependent_variable_at_next_time_index('u', (self._n_siglay, self._n_elems), DTYPE_FLOAT)
        self._v_last = self.mediator.get_time_dependent_variable_at_last_time_index('v', (self._n_siglay, self._n_elems), DTYPE_FLOAT)
        self._v_next = self.mediator.get_time_dependent_variable_at_next_time_index('v', (self._n_siglay, self._n_elems), DTYPE_FLOAT)
        self._omega_last = self.mediator.get_time_dependent_variable_at_last_time_index('omega', (self._n_siglev, self._n_nodes), DTYPE_FLOAT)
        self._omega_next = self.mediator.get_time_dependent_variable_at_next_time_index('omega', (self._n_siglev, self._n_nodes), DTYPE_FLOAT)
        
        # Update memory views for kh
        self._kh_last = self.mediator.get_time_dependent_variable_at_last_time_index('kh', (self._n_siglev, self._n_nodes), DTYPE_FLOAT)
        self._kh_next = self.mediator.get_time_dependent_variable_at_next_time_index('kh', (self._n_siglev, self._n_nodes), DTYPE_FLOAT)
        
        # Update memory views for viscofh
        self._viscofh_last = self.mediator.get_time_dependent_variable_at_last_time_index('viscofh', (self._n_siglay, self._n_nodes), DTYPE_FLOAT)
        self._viscofh_next = self.mediator.get_time_dependent_variable_at_next_time_index('viscofh', (self._n_siglay, self._n_nodes), DTYPE_FLOAT)

    cdef _get_phi(self, DTYPE_FLOAT_t xpos, DTYPE_FLOAT_t ypos, DTYPE_INT_t host,
             DTYPE_FLOAT_t phi[N_VERTICES]):
        cdef int i # Loop counters
        cdef int vertex # Vertex identifier

        # Intermediate arrays
        cdef DTYPE_FLOAT_t x_tri[N_VERTICES]
        cdef DTYPE_FLOAT_t y_tri[N_VERTICES]

        for i in xrange(N_VERTICES):
            vertex = self._nv[i,host]
            x_tri[i] = self._x[vertex]
            y_tri[i] = self._y[vertex]

        # Calculate barycentric coordinates
        interp.get_barycentric_coords(xpos, ypos, x_tri, y_tri, phi)

    cdef _interp_on_sigma_layer(self, DTYPE_FLOAT_t phi[N_VERTICES], DTYPE_INT_t host,
            DTYPE_INT_t kidx):
        """
        Return the linearly interpolated value of sigma on the specified sigma
        layer within the given host element.
        
        Parameters
        ----------
        phi: MemoryView, float
            Array of length three giving the barycentric coordinates at which 
            to interpolate
        host: int
            Host element index
        kidx: int
            Sigma layer on which to interpolate
        Returns
        -------
        sigma: float
            Interpolated value of sigma.
        """
        cdef int vertex # Vertex identifier
        cdef DTYPE_FLOAT_t sigma_nodes[N_VERTICES]
        cdef DTYPE_FLOAT_t sigma # Sigma

        for i in xrange(N_VERTICES):
            vertex = self._nv[i,host]
            sigma_nodes[i] = self._siglay[kidx, vertex]                  

        sigma = interp.interpolate_within_element(sigma_nodes, phi)
        return sigma

    cdef _interp_on_sigma_level(self, DTYPE_FLOAT_t phi[N_VERTICES], DTYPE_INT_t host,
            DTYPE_INT_t kidx):
        """
        Return the linearly interpolated value of sigma on the specified sigma
        level within the given host element.
        
        Parameters
        ----------
        phi: MemoryView, float
            Array of length three giving the barycentric coordinates at which 
            to interpolate
        host: int
            Host element index
        kidx: int
            Sigma layer on which to interpolate
        Returns
        -------
        sigma: float
            Interpolated value of sigma.
        """
        cdef int vertex # Vertex identifier
        cdef DTYPE_FLOAT_t sigma_nodes[N_VERTICES]
        cdef DTYPE_FLOAT_t sigma # Sigma

        for i in xrange(N_VERTICES):
            vertex = self._nv[i,host]
            sigma_nodes[i] = self._siglev[kidx, vertex]                  

        sigma = interp.interpolate_within_element(sigma_nodes, phi)
        return sigma

    cdef _interpolate_vel_between_elements(self, DTYPE_FLOAT_t xpos, 
            DTYPE_FLOAT_t ypos, DTYPE_INT_t host, DTYPE_FLOAT_t vel_elem[N_NEIGH_ELEMS]):

        cdef DTYPE_FLOAT_t rx, ry
        cdef DTYPE_FLOAT_t dudx, dudy
        
        # Interpolate horizontally
        rx = xpos - self._xc[host]
        ry = ypos - self._yc[host]

        dudx = 0.0
        dudy = 0.0
        for i in xrange(N_NEIGH_ELEMS):
            dudx += vel_elem[i] * self._a1u[i, host]
            dudy += vel_elem[i] * self._a2u[i, host]
        return vel_elem[0] + dudx*rx + dudy*ry
