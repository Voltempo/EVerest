// SPDX-License-Identifier: Apache-2.0
// Copyright 2020 - 2025 Pionix GmbH and Contributors to EVerest
#pragma once

#include "everest/io/udp/udp_payload.hpp"
#include <chrono>
#include <everest/io/event/fd_event_handler.hpp>
#include <everest/io/udp/udp_socket.hpp>
#include <functional>
#include <optional>

namespace charge_bridge::utilities {

class sync_udp_client {
public:
    using udp_payload = everest::lib::io::udp::udp_payload;
    using reply = std::optional<udp_payload>;
    /// Cancellation check consulted while waiting for a reply. An empty check makes the request
    /// non-cancellable, i.e. it runs its full timeout/retry budget.
    using abort_check = std::function<bool()>;
    sync_udp_client(std::string const& remote, std::uint16_t port);
    sync_udp_client(std::string const& remote, std::uint16_t port, std::uint16_t retries, std::uint16_t timeout_ms);
    /// @param abort_requested If set, it is polled while waiting for the reply and between retries.
    /// Once it returns true the request gives up and reports a missing reply, so a cancelled request
    /// looks like a failed request to the caller.
    reply request_reply(udp_payload const& payload, abort_check const& abort_requested = {});
    reply request_reply(udp_payload const& payload, std::uint16_t timeout_ms, std::uint16_t retries,
                        abort_check const& abort_requested = {});
    bool tx(udp_payload const& payload);
    reply rx();
    reply rx(std::uint16_t timeout_ms);
    bool is_open();

private:
    void init(std::string const& remote, std::uint16_t port);
    void clear_socket();
    /// Wait up to \p timeout for a reply. With an armed \p abort_requested the wait is sliced, so
    /// the check runs regularly instead of only after the full timeout has elapsed.
    bool poll_for_reply(std::chrono::milliseconds timeout, abort_check const& abort_requested);

    std::uint16_t m_retries;
    std::uint16_t m_timeout_ms;
    everest::lib::io::udp::udp_client_socket m_udp;
    everest::lib::io::event::fd_event_handler m_handler;
};

} // namespace charge_bridge::utilities
