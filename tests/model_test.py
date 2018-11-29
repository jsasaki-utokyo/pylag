from unittest import TestCase
import numpy.testing as test
import numpy as np
from ConfigParser import SafeConfigParser

from pylag.model import OPTModel

from pylag.tests.model_test_helpers import TestOPTModelDataReader

class OPTModel_test1(TestCase):
    """ Ensure the model behaves sensible given an invalid particle seed """

    def setUp(self):
        # Create config
        config = SafeConfigParser()
        config.add_section("GENERAL")
        config.set('GENERAL', 'log_level', 'info')
        config.add_section("SIMULATION")
        config.set('SIMULATION', 'depth_coordinates', 'depth_below_surface')
        config.add_section("NUMERICS")
        config.set('NUMERICS', 'num_method', 'test')
        
        # Create test data reader
        data_reader = TestOPTModelDataReader()
        
        # Create data reader
        self.model = OPTModel(config, data_reader)

    def tearDown(self):
        del(self.model)

    def test_all_seed_particles_lie_outside_of_the_model_domain(self):
        group_ids = np.array([1,1])
        x_positions = np.array([-1., -1.])
        y_positions = np.array([-1., -1.])
        z_positions = np.array([-1., -1.])
        time = 0.0
        self.model.set_particle_data(group_ids, x_positions, y_positions, z_positions)
        self.assertRaises(RuntimeError, self.model.seed, time)


class OPTModel_test2(TestCase):
    """ Ensure initial vertical grid positions are properly checked
    
    Checks performed for the case in which vertical coordinates are specified
    relative to the free surface.
    """

    def setUp(self):
        # Create config
        config = SafeConfigParser()
        config.add_section("GENERAL")
        config.set('GENERAL', 'log_level', 'info')
        config.add_section("SIMULATION")
        config.set('SIMULATION', 'depth_coordinates', 'depth_below_surface')
        config.add_section("NUMERICS")
        config.set('NUMERICS', 'num_method', 'test')
        
        # Create test data reader
        data_reader = TestOPTModelDataReader()
        
        # Create data reader
        self.model = OPTModel(config, data_reader)

    def tearDown(self):
        del(self.model)

    def test_seed_particle_is_above_the_free_surface(self):
        group_ids = np.array([1])
        x_positions = np.array([0.5])
        y_positions = np.array([0.5])
        z_positions = np.array([0.1])
        time = 0.0
        self.model.set_particle_data(group_ids, x_positions, y_positions, z_positions)
        self.assertRaises(ValueError, self.model.seed, time)


class OPTModel_test3(TestCase):
    """ Ensure initial vertical grid positions are properly checked
    
    Checks performed for the case in which vertical coordinates are specified
    relative to the sea floor.
    """

    def setUp(self):
        # Create config
        config = SafeConfigParser()
        config.add_section("GENERAL")
        config.set('GENERAL', 'log_level', 'info')
        config.add_section("SIMULATION")
        config.set('SIMULATION', 'depth_coordinates', 'depth_below_surface')
        config.add_section("NUMERICS")
        config.set('NUMERICS', 'num_method', 'test')
        
        # Create test data reader
        data_reader = TestOPTModelDataReader()
        
        # Create data reader
        self.model = OPTModel(config, data_reader)

    def tearDown(self):
        del(self.model)

    def test_seed_particle_is_below_the_sea_floor(self):
        group_ids = np.array([1])
        x_positions = np.array([0.5])
        y_positions = np.array([0.5])
        z_positions = np.array([-1.1])
        time = 0.0
        self.model.set_particle_data(group_ids, x_positions, y_positions, z_positions)
        self.assertRaises(ValueError, self.model.seed, time)