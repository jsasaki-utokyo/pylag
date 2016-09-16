from pylag.model import FVCOMOPTModel
from pylag.fvcom_data_reader import FVCOMDataReader

# Serial imports
from pylag.mediator import SerialMediator

def get_model(config):
    if config.get("OCEAN_CIRCULATION_MODEL", "name") == "FVCOM":
        mediator = SerialMediator(config)
        data_reader = FVCOMDataReader(config, mediator)
        return FVCOMOPTModel(config, data_reader)
    else:
        raise ValueError('Unsupported ocean circulation model.')