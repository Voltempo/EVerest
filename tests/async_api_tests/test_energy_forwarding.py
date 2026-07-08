import asyncio
import queue

import pytest

from everest.testing.core_utils.probe_module import ProbeModule
from everest.testing.core_utils.everest_core import EverestCore
from everest.testing.core_utils.fixtures import *


@pytest.fixture
def probe_module(everest_core: EverestCore) -> ProbeModule:
    everest_core.start(standalone_module='probe')
    return ProbeModule(everest_core.get_runtime_session())


@pytest.mark.everest_core_config('probe-energy.yaml')
def test_energy_node_forwards_rotated_powermeter_reading(probe_module: ProbeModule):
    """
    Verifies EnergyNode's real pub/sub wiring end-to-end, not just the underlying rotation math
    (already covered by lib/everest/phase_rotation/tests) or the isolated wiring unit tests in
    modules/EnergyManagement/EnergyNode/tests: a raw powermeter reading injected on EnergyNode's
    "powermeter" connection must be rotated according to the configured phase_rotation ("312" in
    probe-energy.yaml) and forwarded as energy_usage_root in the energy_flow_request published on
    EnergyNode's "energy_grid" interface -- the same interface EnergyManager consumes as its
    energy_trunk in this config.
    """
    energy_flow_requests = probe_module.subscribe_variable_to_queue('energy_observer', 'energy_flow_request')

    # Stand in for EnergyNode's required downstream child. EnergyManager periodically propagates
    # enforced limits down through EnergyNode to its children -- if this is left unimplemented,
    # EVerest will hang waiting for a response (see ProbeModule.implement_command docs).
    probe_module.implement_command('energy_consumer_probe', 'enforce_limits', lambda args: {})

    # The "powermeter" interface also declares start_transaction/stop_transaction; EnergyNode never
    # calls them, but the framework requires every implementation to cover the full manifest.
    probe_module.implement_command('powermeter_probe', 'start_transaction', lambda args: {"status": "OK"})
    probe_module.implement_command('powermeter_probe', 'stop_transaction', lambda args: {"status": "OK"})

    probe_module.start()
    asyncio.run(probe_module.wait_to_be_ready(timeout=10.0))

    raw_reading = {
        "timestamp": "2024-01-01T00:00:00Z",
        "energy_Wh_import": {"total": 0.0, "L1": 1.0, "L2": 2.0, "L3": 3.0},
        "voltage_V": {"L1": 231.0, "L2": 232.0, "L3": 233.0},
    }
    probe_module.publish_variable('powermeter_probe', 'powermeter', raw_reading)

    # EnergyNode republishes its energy_flow_request whenever new input arrives; find the first
    # one that already carries our injected (and, if correct, rotated) reading.
    energy_usage_root = None
    try:
        while True:
            flow_request = energy_flow_requests.get(timeout=10.0)
            if flow_request.get("energy_usage_root"):
                energy_usage_root = flow_request["energy_usage_root"]
                break
    except queue.Empty:
        pass

    assert energy_usage_root is not None, "Did not receive an energy_flow_request with energy_usage_root in time"

    voltage = energy_usage_root["voltage_V"]
    assert voltage["L1"] == pytest.approx(233.0)
    assert voltage["L2"] == pytest.approx(231.0)
    assert voltage["L3"] == pytest.approx(232.0)

    energy_import = energy_usage_root["energy_Wh_import"]
    assert energy_import["L1"] == pytest.approx(3.0)
    assert energy_import["L2"] == pytest.approx(1.0)
    assert energy_import["L3"] == pytest.approx(2.0)
