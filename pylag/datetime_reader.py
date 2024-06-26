"""
A family of classes for reading dates/times.
"""
import numpy as np
from netCDF4 import Dataset
from cftime import num2pydate
from datetime import timedelta
try:
    import configparser
except ImportError:
    import ConfigParser as configparser

from pylag.exceptions import PyLagValueError, PyLagRuntimeError
from pylag.utils import round_time


class DateTimeReader:
    """ Abstract base class for DateTimeReaders

    DatetimeReaders are responsible for reading in and processing
    datetime data within NetCDF4 datasets. Different models encode
    time in different ways. Hence, we introduce a family of objects
    to account for all possible approaches.
    """
    def get_datetime(self, dataset, time_index=None):
        """ Get dates/times for the given dataset

        Must be implemented in a derived class.

        Parameters
        ----------
        dataset : Dataset
            Dataset object for an FVCOM data file.

        time_index : int, optional
            The time index at which to extract data.
        """
        raise NotImplementedError


class DefaultDateTimeReader(DateTimeReader):
    """ Default Datetime reader

    Default datetime readers read in datetime information from a single variable
    in the NetCDF dataset. The name of the time variable should be given
    in the run config file. If one is not given, it defaults to the name `time`.

    Parameters
    ----------
    config : ConfigParser
        A run configuration object,

    config_section_name : str
        String identifying the type of data the time variable is associated
        with.
    """
    def __init__(self, config, config_section_name):
        self.config = config
        self.config_section_name = config_section_name

        # Time variable name
        try:
            self._time_var_name = self.config.get(self.config_section_name,
                                                  "time_var_name").strip()
        except configparser.NoOptionError:
            self._time_var_name = "time"

        self.rounding_interval = self.config.getint(self.config_section_name,
                                                    "rounding_interval")

    def get_datetime(self, dataset, time_index=None):
        """ Get dates/times for the given dataset

        This function searches for the basic variable `time`.
        If a given source of data uses a different variable
        name or approach to saving time points, support for
        them can be added through subclassing (as with
        FVCOM) DateTimeReader.

        Parameters
        ----------
        dataset : Dataset
            Dataset object for an FVCOM data file.

        time_index : int, optional
            The time index at which to extract data. Default behaviour
            is to return the full time array as datetime objects.

        Returns
        -------
         : list[datetime]
             If `time_index` is None, return a full list of datetime
             objects.

         : Datetime
             If `time_index` is not None, a single datetime object.
        """
        time_raw = dataset.variables[self._time_var_name]
        units = dataset.variables[self._time_var_name].units

        if time_index is not None:
            datetime_raw = num2pydate(time_raw[time_index], units=units)
            return round_time([datetime_raw], self.rounding_interval)[0]
        else:
            datetime_raw = num2pydate(time_raw[:], units=units)
            return round_time(datetime_raw, self.rounding_interval)


class FVCOMDateTimeReader(DateTimeReader):
    """ FVCOM Datetime reader

    FVCOM datetime readers read in datetime information from a NetCDF input
    file generated by FVCOM.

    Attributes
    ----------
    config : ConfigParser
        See Parameters.

    config_section_name : str
        See Parameters.

    rounding_interval : int
        Apply rounding to datetime object using this interval, which is given
        in seconds.

    Parameters
    ----------
    config : ConfigParser
        A run configuration object,

    config_section_name : str
        String identifying the type of data the time variable is associated
        with.
    """
    def __init__(self, config, config_section_name):
        self.config = config
        self.config_section_name = config_section_name

        self.rounding_interval = self.config.getint(self.config_section_name,
                                                    "rounding_interval")

        self.days_per_milli_second = 1. / (1000. * 60. * 60. * 24.)

    def get_datetime(self, dataset, time_index=None):
        """ Get FVCOM dates/times for the given dataset

        The time variable in FVCOM has the lowest precision. Instead,
        we construct the time array from the Itime and Itime2 vars,
        before then constructing datetime objects.

        Parameters
        ----------
        dataset : Dataset
            Dataset object for an FVCOM data file.

        time_index : int, optional
            The time index at which to extract data. Default behaviour
            is to return the full time array as datetime objects.

        Returns
        -------
         : list[datetime]
             If `time_index` is None, return a full list of datetime objects.

         : Datetime
        """
        time_raw = (dataset.variables['Itime'][:] +
                    dataset.variables['Itime2'][:] * self.days_per_milli_second)
        units = dataset.variables['Itime'].units

        if time_index is not None:
            datetime_raw = num2pydate(time_raw[time_index], units=units)
            return round_time([datetime_raw], self.rounding_interval)[0]
        else:
            datetime_raw = num2pydate(time_raw[:], units=units)
            return round_time(datetime_raw, self.rounding_interval)


def get_datetime_reader(config, config_section_name):
    """ Factory method for datetime readers

    There is a hierarchy of data sources. At the top level, the
    source may be associated with ocean, atmosphere or wave data. Below
    that, in principle, there are multiple types of ocean, atmosphere
    and wave data. The top-level data source must be specified through the
    appropriate config section name. This is then used to construct the
    required date time reader.

    Parameters
    ----------
    config : ConfigParser
        Configuration object

    config_section_name : str
        String identifying the type of data the time variable is associated
        with (e.g. WAVE_DATA, ATMOSPHERE_DATA etc).

    Returns
    -------
     : DatetimeReader
         A DatetimeReader.
    """
    # The name of the data source (e.g. FVCOM, ROMS etc)
    name = config.get(config_section_name, "name")

    if name == "FVCOM":
        return FVCOMDateTimeReader(config, config_section_name)

    return DefaultDateTimeReader(config, config_section_name)


__all__ = ["DateTimeReader",
           "DefaultDateTimeReader",
           "FVCOMDateTimeReader",
           "get_datetime_reader"]
