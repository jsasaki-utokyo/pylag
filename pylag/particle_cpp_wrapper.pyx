from cython.operator cimport dereference as deref

from libcpp.vector cimport vector
from libcpp.string cimport string

# Data types
from pylag.data_types_cython cimport DTYPE_INT_t, DTYPE_FLOAT_t


cdef class ParticleSmartPtr:
    """ Python object for managing the memory associated with Particle objects
    
    This class ties the lifetime of a Particle object allocated on the heap to 
    the lifetime of a ParticleSmartPtr object.
    """
    
    def __cinit__(self, DTYPE_INT_t group_id=-999, DTYPE_FLOAT_t x1=-999., 
                  DTYPE_FLOAT_t x2=-999., DTYPE_FLOAT_t x3=-999., phis={},
                  DTYPE_FLOAT_t omega_interfaces=-999.,
                  DTYPE_FLOAT_t omega_layers=-999., bint in_domain=False,
                  DTYPE_INT_t is_beached=0, host_elements={},
                  DTYPE_INT_t k_layer=-999, bint in_vertical_boundary_layer=False,
                  DTYPE_INT_t k_lower_layer=-999, DTYPE_INT_t k_upper_layer=-999,
                  DTYPE_INT_t id=-999, DTYPE_INT_t status=0, ParticleSmartPtr particle_smart_ptr=None):

        cdef ParticleSmartPtr _particle_smart_ptr

        # Call copy ctor if particle_smart_ptr is given. Else, use default ctor
        if particle_smart_ptr and type(particle_smart_ptr) is ParticleSmartPtr:
            _particle_smart_ptr = <ParticleSmartPtr> particle_smart_ptr
            self._particle = new Particle(deref(_particle_smart_ptr._particle))

        else:
            self._particle = new Particle()

            # Overwrite with supplied optional arguments
            self._particle.set_group_id(group_id)
            self._particle.set_id(id)
            self._particle.set_status(status)
            self._particle.set_x1(x1)
            self._particle.set_x2(x2)
            self._particle.set_x3(x3)
            self._particle.set_omega_interfaces(omega_interfaces)
            self._particle.set_omega_layers(omega_layers)
            self._particle.set_in_domain(in_domain)
            self._particle.set_is_beached(is_beached)
            self._particle.set_k_layer(k_layer)
            self._particle.set_in_vertical_boundary_layer(in_vertical_boundary_layer)
            self._particle.set_k_lower_layer(k_lower_layer)
            self._particle.set_k_upper_layer(k_upper_layer)

            # Set local coordinates on all grids
            self.set_all_phis(phis)

            # Add hosts
            self.set_all_host_horizontal_elems(host_elements)

        if not self._particle:
            raise MemoryError()

    def __dealloc__(self):
        del self._particle

    cdef Particle* get_ptr(self):
        return self._particle

    def get_particle_data(self):
        """ Get particle data

        Return data describing the particle's basic state. Do not return
        any derived data (e.g. particle local coordinates). The purpose
        is to return just enough data to make it possible to recreate
        the particle at some later time (e.g. from a restart file).

        Returns:
        --------
        data : dict
            Dictionary containing data that describes the particle's basic state.
        """

        data = {'group_id': self._particle.get_group_id(),
                'x1': self._particle.get_x1(),
                'x2': self._particle.get_x2(),
                'x3': self._particle.get_x3()}

        return data

    def set_phi(self, grid, phi):
        grid_name = grid.encode() if type(grid) == str else grid
        self._particle.set_phi(grid_name, phi)

    def get_phi(self, grid):
        grid_name = grid.encode() if type(grid) == str else grid

        phi = []
        for x in self._particle.get_phi(grid_name):
            phi.append(x)
        return phi

    def set_all_phis(self, phis):
        self._particle.clear_phis()
        for grid, phi in phis.items():
            self.set_phi(grid, phi)

    def set_host_horizontal_elem(self, grid, host):
        grid_name = grid.encode() if type(grid) == str else grid
        self._particle.set_host_horizontal_elem(grid_name, host)

    def get_host_horizontal_elem(self, grid):
        grid_name = grid.encode() if type(grid) == str else grid
        return self._particle.get_host_horizontal_elem(grid_name)

    def set_all_host_horizontal_elems(self, host_elements):
        self._particle.clear_host_horizontal_elems()
        for grid, host in host_elements.items():
            self.set_host_horizontal_elem(grid, host)

    def get_all_host_horizontal_elems(self):
        cdef vector[string] grids
        cdef vector[int] hosts
        self._particle.get_all_host_horizontal_elems(grids, hosts)

        host_elements = {}
        for grid, host in zip(grids, hosts):
            host_elements[grid.decode()] = host

        return host_elements

    @property
    def status(self):
        return self._particle.get_status()

    @property
    def x1(self):
        return self._particle.get_x1()

    @property
    def x2(self):
        return self._particle.get_x2()

    @property
    def x3(self):
        return self._particle.get_x3()

    @property
    def omega_interfaces(self):
        return self._particle.get_omega_interfaces()

    @property
    def omega_layers(self):
        return self._particle.get_omega_layers()

    @property
    def in_domain(self):
        return self._particle.get_in_domain()

    @property
    def is_beached(self):
        return self._particle.get_is_beached()

    @property
    def k_layer(self):
        return self._particle.get_k_layer()

    @property
    def k_lower_layer(self):
        return self._particle.get_k_lower_layer()

    @property
    def k_upper_layer(self):
        return self._particle.get_k_upper_layer()

    @property
    def in_vertical_boundary_layer(self):
        return self._particle.get_in_vertical_boundary_layer()


cdef ParticleSmartPtr copy(ParticleSmartPtr particle_smart_ptr):
    """ Create a copy of a ParticleSmartPtr object
    
    This function creates a new copy a ParticleSmartPtr object. In so doing
    new memory is allocated. This memory is automatically freed when the
    ParticleSmartPtr is deleted.
    
    Parameters:
    -----------
    particle_smart_ptr : ParticleSmartPtr
        ParticleSmartPtr object.
    
    Returns:
    --------
    particle_smart_ptr : ParticleSmartPtr
        An exact copy of the ParticleSmartPtr object passed in.
    """

    return ParticleSmartPtr(particle_smart_ptr=particle_smart_ptr)


cdef to_string(Particle* particle):
    """ Return a string object that describes a particle

    TODO:
    -----
    1) Add back in host elements
    2) Add back in phis

    Parameters:
    -----------
    particle : Particle C ptr
        Pointer to a particle object

    Returns:
    --------
    s : str
        String describing the particle
    """

    s = "Particle properties \n"\
        "------------------- \n"\
        "Particle id = {} \n"\
        "Particle x1 = {} \n"\
        "Particle x2 = {} \n"\
        "Particle x3 = {} \n"\
        "Particle omega interfaces = {} \n"\
        "Particle omega layers = {} \n"\
        "Partilce in vertical boundary layer = {} \n"\
        "Partilce k layer = {} \n"\
        "Partilce k lower layer = {} \n"\
        "Partilce k upper layer = {} \n"\
        "Particle in domain = {} \n"\
        "Particle is beached = {} \n".format(particle.get_id(),
                                             particle.get_x1(),
                                             particle.get_x2(),
                                             particle.get_x3(),
                                             particle.get_omega_interfaces(),
                                             particle.get_omega_layers(),
                                             particle.get_in_vertical_boundary_layer(),
                                             particle.get_k_layer(),
                                             particle.get_k_lower_layer(),
                                             particle.get_k_upper_layer(),
                                             particle.get_in_domain(),
                                             particle.get_is_beached())

    return s
