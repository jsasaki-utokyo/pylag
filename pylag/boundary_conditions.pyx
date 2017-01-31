from libc.math cimport sqrt

# PyLag cimports
from pylag.math cimport inner_product

cdef class HorizBoundaryConditionCalculator:

     cpdef apply(self, DataReader data_reader, DTYPE_FLOAT_t x_old,
            DTYPE_FLOAT_t y_old, DTYPE_FLOAT_t x_new, DTYPE_FLOAT_t y_new,
            DTYPE_INT_t last_host):
        pass

cdef class RefHorizBoundaryConditionCalculator(HorizBoundaryConditionCalculator):

    cpdef apply(self, DataReader data_reader, DTYPE_FLOAT_t x_old,
            DTYPE_FLOAT_t y_old, DTYPE_FLOAT_t x_new, DTYPE_FLOAT_t y_new,
            DTYPE_INT_t last_host):
        """Apply reflecting boundary conditions
        
        """
        # 2D position vectors for the end points of the element's side
        cdef DTYPE_FLOAT_t x1[2]
        cdef DTYPE_FLOAT_t x2[2]
        
        # 2D position vectors for the particle's previous and new position
        cdef DTYPE_FLOAT_t x3[2]
        cdef DTYPE_FLOAT_t x4[2]
        
        # 2D position vector for the intersection point
        cdef DTYPE_FLOAT_t xi[2]
        
        # 2D position vector for the reflected position
        cdef DTYPE_FLOAT_t x4_prime[2]
        
        # 2D directoion vector normal to the element side, pointing into the
        # element
        cdef DTYPE_FLOAT_t n[2]     
        
        # 2D direction vector pointing from xi to x4
        cdef DTYPE_FLOAT_t d[2]
        
        # 2D direction vector pointing from xi to x4', where x4' is the
        # reflected point that we ultimately trying to find
        cdef DTYPE_FLOAT_t r[2]
        
        # Intermediate variable
        cdef DTYPE_FLOAT_t mult

        # Construct arrays to hold the coordinates of the particle's previous
        # position vector and its new position vector that lies outside of the
        # model domain
        x3[0] = x_old; x3[1] = y_old
        x4[0] = x_new; x4[1] = y_new

        # Compute coordinates for the side of the element the particle crossed
        # before exiting the domain
        x1[0], x1[1], x2[0], x2[1], xi[0], xi[1] = data_reader.get_boundary_intersection(x_old,
                y_old, x_new, y_new, last_host)

        # Compute the direction vector pointing from the intersection point
        # to the position vector that lies outside of the model domain
        for i in xrange(2):
            d[i] = x4[i] - xi[i]

        # Compute the normal to the element side that points back into the
        # element given the clockwise ordering of element vertices
        n[0] = x2[1] - x1[1]; n[1] = x1[0] - x2[0]

        # Compute the reflection vector
        mult = 2.0 * inner_product(n, d) / inner_product(n, n)
        for i in xrange(2):
            r[i] = d[i] - mult*n[i]
            x4_prime[i] = xi[i] + r[i]

        # Return coordinates of the reflected point
        return x4_prime[0], x4_prime[1]

def get_horiz_boundary_condition_calculator(config):
    # Return the specified numerical integrator.
    if config.get("SIMULATION", "horiz_bound_cond") == "reflecting":
        return RefHorizBoundaryConditionCalculator()
    elif config.get("SIMULATION", "horiz_bound_cond") == "None":
        return None
    else:
        raise ValueError('Unsupported horizontal boundary condtion.')


