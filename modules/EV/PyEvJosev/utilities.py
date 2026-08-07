# SPDX-License-Identifier: Apache-2.0
# Copyright 2020 - 2023 Pionix GmbH and Contributors to EVerest
import logging
import netifaces

from everest.framework import log

from iso15118.evcc.evcc_config import EVCCConfig
from iso15118.shared.utils import load_requested_protocols, load_requested_energy_services

class EverestPyLoggingHandler(logging.Handler):

    def __init__(self):
        logging.Handler.__init__(self)

    def emit(self, record):
        msg = self.format(record)

        log_level: int = record.levelno
        if log_level == logging.CRITICAL:
            log.critical(msg)
        elif log_level == logging.ERROR:
            log.error(msg)
        elif log_level == logging.WARNING:
            log.warning(msg)
        # FIXME (aw): implicitely pipe everything with loglevel INFO into DEBUG
        else:
            log.debug(msg)


def setup_everest_logging():
    # remove all logging handler so that we'll have only our custom one
    # FIXME (aw): this is probably bad practice because if everyone does that, only the last one might survive
    logging.getLogger().handlers.clear()

    handler = EverestPyLoggingHandler()

    # NOTE (aw): the default formatting should be fine
    # formatter = logging.Formatter("%(levelname)s - %(name)s (%(lineno)d): %(message)s")
    # handler.setFormatter(formatter)

    logging.getLogger().addHandler(handler)


def choose_first_ipv6_local() -> str:
    for iface in netifaces.interfaces():
        if netifaces.AF_INET6 in netifaces.ifaddresses(iface):
            for netif_inet6 in netifaces.ifaddresses(iface)[netifaces.AF_INET6]:
                if 'fe80' in netif_inet6['addr']:
                    return iface

    log.warning('No necessary IPv6 link-local address was found!')
    return 'eth0'


def determine_network_interface(preferred_interface: str) -> str:
    if preferred_interface == "auto":
        return choose_first_ipv6_local()
    elif preferred_interface not in netifaces.interfaces():
        log.warning(
            f"The network interface {preferred_interface} was not found!")

    return preferred_interface


MAC_ADDRESS_HEX_DIGITS = 12
EVCC_ID_SEPARATORS = (':', '-', '.', ' ')
VID_PREFIX = 'VID:'


def normalize_evcc_id(value: str) -> str:
    """
    Turn a MAC address written in any of the forms a user is likely to type into the 12 uppercase hex digits
    that DIN 70121 and ISO 15118-2 expect in SessionSetupReq. Accepts "VID:0242AC110099", "02:42:AC:11:00:99",
    "02-42-ac-11-00-99" and "0242ac110099" alike, and returns an empty string for anything that is not a MAC
    address.

    The "VID:" prefix belongs to the OCPP token, not to the EVCCID - EvseManager prepends it again on the
    charging station side - so it is accepted for convenience and then stripped.
    """
    candidate = value.strip()

    if candidate.upper().startswith(VID_PREFIX):
        candidate = candidate[len(VID_PREFIX):]

    for separator in EVCC_ID_SEPARATORS:
        candidate = candidate.replace(separator, '')

    if len(candidate) != MAC_ADDRESS_HEX_DIGITS:
        return ''

    try:
        int(candidate, 16)
    except ValueError:
        return ''

    return candidate.upper()


def patch_josev_config(josev_config: EVCCConfig, everest_config: dict) -> None:

    josev_config.use_tls = everest_config['tls_active']

    josev_config.enforce_tls = everest_config['enforce_tls']

    josev_config.is_cert_install_needed = everest_config['is_cert_install_needed']

    josev_config.sdp_retry_cycles = 1

    protocols = [
        "DIN_SPEC_70121",
        "ISO_15118_2",
        "ISO_15118_20_AC",
        "ISO_15118_20_DC",
    ]

    if not everest_config['supported_DIN70121']:
        protocols.remove('DIN_SPEC_70121')

    if not everest_config['supported_ISO15118_2']:
        protocols.remove('ISO_15118_2')

    if not everest_config['supported_ISO15118_20_AC']:
        protocols.remove('ISO_15118_20_AC')

    if not everest_config['supported_ISO15118_20_DC']:
        protocols.remove('ISO_15118_20_DC')

    if not protocols:
        log.error("The supporting hlc protocols were not specified")

    josev_config.supported_protocols = load_requested_protocols(protocols)

    if everest_config['supported_d20_energy_services']:
        josev_config.supported_energy_services = load_requested_energy_services(
            everest_config['supported_d20_energy_services'].split(',')
        )
    else:
        josev_config.supported_energy_services = load_requested_energy_services(
             ['DC']
        )


class _AuthorisationTimeoutOverride:
    """
    Stands in for Josev's shared Timeouts table, widening only the two values the EVCC uses as a budget for
    "how long will I keep asking to be authorised". Every other timeout falls through to the real table unchanged.

    Josev applies V2G_SECC_Sequence_Timeout (DIN, din_spec_states.ContractAuthentication) and
    V2G_EVCC_Ongoing_Timeout (ISO 15118-2, iso15118_2_states.Authorization) - both 60 s - as cumulative
    authorisation budgets. V2G_SECC_Sequence_Timeout is not that: it is the per-message-pair limit, the gap between
    a request and its response. Using it to bound a whole authorisation is a misreading, and it makes the simulated
    car abandon the session, permanently, 60 s after plugging in.

    That is far stricter than any of the specs in play:

        DIN SPEC 70121 Table 77   V2G_EVCC_ReadyToCharge_Timeout   250 s   (defined, and unused by Josev)
        ISO 15118-20              EIM ongoing authorisation        180 s   (lib/everest/iso15118, TIMEOUT_EIM_ONGOING)
        EVerest's own SECC        auth_timeout_eim                 300 s   (EvseV2G manifest default; 0 = forever)

    and it matters because on a CSMS the authorisation is a person pressing a button.
    """

    def __init__(self, wrapped, seconds: float) -> None:
        self._wrapped = wrapped
        self.V2G_SECC_SEQUENCE_TIMEOUT = seconds
        self.V2G_EVCC_ONGOING_TIMEOUT = seconds

    def __getattr__(self, name):
        return getattr(self._wrapped, name)


def patch_josev_authorisation_timeout(seconds: float) -> None:
    """
    Widens how long the simulated car will wait to be authorised, by rebinding the Timeouts table the EVCC state
    modules imported. Josev's own table is an Enum and cannot be edited in place, but both modules bound it with a
    plain module-level import, so replacing that name reaches every use.

    Pass 0 to leave Josev's stock 60 s alone.
    """

    if seconds <= 0:
        log.info('EV authorisation timeout: leaving the Josev default of 60 s in place')
        return

    from iso15118.shared.messages.timeouts import Timeouts as SharedTimeouts
    import iso15118.evcc.states.din_spec_states as din_spec_states
    import iso15118.evcc.states.iso15118_2_states as iso15118_2_states

    override = _AuthorisationTimeoutOverride(SharedTimeouts, float(seconds))

    din_spec_states.TimeoutsShared = override
    iso15118_2_states.TimeoutsShared = override

    log.info(f'EV will wait up to {seconds:.0f} s to be authorised, instead of the Josev default of 60 s')


class HlcGaveUp(BaseException):
    """
    Raised when the EVCC has exhausted its SDP retry budget and Josev would otherwise sit spinning.

    Deliberately a BaseException: Josev catches SDPFailedError in two places and Exception in a third, and this
    has to escape all of them so the session coroutine can finish. Finishing is the whole point - EVerest's
    start_evcc_handler already builds a fresh EVCCHandler for every start_charging, so the moment the old one
    returns, the next plug-in gets a working stack.
    """


def patch_josev_sdp_budget_recovery() -> None:
    """
    Makes the simulated car recover after its ISO 15118 stack shuts down, which upstream Josev does not do
    despite its own error message promising it.

    Josev counts SDP retry *cycles* on the CommunicationSessionHandler: _sdp_retry_cycles is set once in
    __init__ and only ever decremented. When it hits zero the handler raises SDPFailedError with

        "Shutting down high-level communication. Unplug and plug in the cable again if you want to start anew."

    which is untrue - the budget lives on the handler, not on the cable, so replugging changes nothing and the
    connector stays unable to charge until the manager is restarted. That is a real cost on a CSMS rig, where
    every authorisation a person is slow to press burns the budget for good.

    The handler itself survives: both places that catch SDPFailedError sit inside get_from_rcv_queue's main
    loop and carry Josev's own "TODO not sure what else to do here". So the fix is not to restart anything, it
    is to hand the budget back on the way out - after which the next plug-in genuinely does start anew.
    """

    from iso15118.evcc.comm_session_handler import (
        CommunicationSessionHandler,
        SDP_MAX_REQUEST_COUNTER,
    )
    from iso15118.shared.exceptions import SDPFailedError

    if getattr(CommunicationSessionHandler.restart_sdp, '_voltempo_budget_recovery', False):
        return

    original_restart_sdp = CommunicationSessionHandler.restart_sdp

    async def restart_sdp_with_budget_recovery(self, new_sdp_cycle: bool):
        try:
            return await original_restart_sdp(self, new_sdp_cycle)
        except SDPFailedError:
            # Still raised, so Josev's own flow is untouched - it logs and returns to the queue loop. The
            # difference is that the next cable-in starts with a full budget instead of a dead stack.
            self._sdp_retry_cycles = self.config.sdp_retry_cycles
            self.sdp_retries_number = SDP_MAX_REQUEST_COUNTER
            log.warning(
                'ISO 15118 discovery gave up; ending this session so the next plug-in starts a fresh stack '
                'rather than needing an EVerest restart'
            )
            raise HlcGaveUp from None

    restart_sdp_with_budget_recovery._voltempo_budget_recovery = True
    CommunicationSessionHandler.restart_sdp = restart_sdp_with_budget_recovery

    log.info('ISO 15118 stack will recover its SDP retry budget after a shutdown')
