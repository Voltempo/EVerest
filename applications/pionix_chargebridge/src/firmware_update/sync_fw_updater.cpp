// SPDX-License-Identifier: Apache-2.0
// Copyright 2020 - 2025 Pionix GmbH and Contributors to EVerest
#include "everest/io/udp/udp_payload.hpp"
#include <charge_bridge/firmware_update/sync_fw_updater.hpp>
#include <charge_bridge/utilities/filesystem.hpp>
#include <charge_bridge/utilities/logging.hpp>
#include <charge_bridge/utilities/platform_utils.hpp>

#include <protocol/cb_management.h>

#include <cstring>
#include <fstream>

namespace {
const int default_udp_timeout_ms = 3000;
}

namespace charge_bridge::firmware_update {

const std::uint32_t sync_fw_updater::app_udp_sector_size = 0x2000;
const std::uint16_t sync_fw_updater::sub_chunk_size = 1024;

using namespace everest::lib::io::udp;

static everest::lib::io::udp::udp_payload make_ping_command() {
    everest::lib::io::udp::udp_payload payload;

    CbManagementPacket<CbFirmwarePing> packet;
    packet.type = CbStructType::CST_CbFirmwarePing;
    packet.data.dummy = 0;
    utilities::struct_to_vector(packet, payload.buffer);

    return payload;
}

static everest::lib::io::udp::udp_payload make_get_version_command() {
    everest::lib::io::udp::udp_payload payload;

    CbManagementPacket<CbFirmwareGetVersion> packet;
    packet.type = CbStructType::CST_CbFirmwareGetVersion;
    packet.data.dummy = 0;
    utilities::struct_to_vector(packet, payload.buffer);

    return payload;
}

sync_fw_updater::sync_fw_updater(fw_update_config const& config, std::function<bool()> abort_requested) :
    m_udp(config.cb_remote, config.cb_port, 3, default_udp_timeout_ms),
    m_config(config),
    m_abort_requested(std::move(abort_requested)) {
}

bool sync_fw_updater::is_abort_requested() const {
    return m_abort_requested and m_abort_requested();
}

std::optional<std::string> sync_fw_updater::get_fw_version() {
    auto pl = make_get_version_command();

    auto result = m_udp.request_reply(pl, m_abort_requested);
    if (not result) {
        return std::nullopt;
    }

    result->buffer[result->buffer.size() - 1] = 0x00;               // ensure it is actually a 0 terminated string
    auto* str_ptr = reinterpret_cast<char*>(result->buffer.data()); // reinterpret for string conversion
    return std::string(str_ptr + 2);                                // skip 2 byte header
}

void sync_fw_updater::print_fw_version() {
    auto result = get_fw_version();
    utilities::print_error(m_config.cb, "FIRMWARE", not result.has_value())
        << "Firmware version " << result.value_or(is_abort_requested() ? "ABORTED" : "ERROR") << std::endl;
}

bool sync_fw_updater::check_if_correct_fw_installed() {
    auto installed_fw = get_fw_version();

    if (not installed_fw.has_value()) {
        // A cancelled version probe must not be mistaken for "the device already runs the right
        // firmware": report a mismatch so the caller's own abort handling decides what happens next.
        return not is_abort_requested();
    }

    charge_bridge::filesystem_utils::CryptSignedHeader hdr;
    std::uint32_t offset;
    if (not read_crypt_signed_header(m_config.fw_path, hdr, offset)) {
        utilities::print_error(m_config.cb, "FIRMWARE", 1)
            << "Could not read header for file: " << m_config.fw_path << std::endl;
        return false;
    }
    auto available_fw = hdr.firmware_version;

    utilities::print_error(m_config.cb, "FIRMWARE", 0)
        << "Firmware installed: \"" << installed_fw.value() << "\" Firmware available: \"" << available_fw << "\""
        << std::endl;

    if (installed_fw.value() == available_fw) {
        return true;
    } else {
        return false;
    }
}

bool sync_fw_updater::quick_check_connection() {
    static const std::uint16_t rr_timeout_ms = 200;
    static const std::uint16_t rr_retires_ms = 10;

    everest::lib::io::udp::udp_payload pl = make_ping_command();
    auto result = m_udp.request_reply(pl, rr_timeout_ms, rr_retires_ms, m_abort_requested).has_value();
    utilities::print_error(m_config.cb, "FIRMWARE", not result) << connection_result_message(result) << std::endl;
    return result;
}

bool sync_fw_updater::check_connection() {
    static const std::uint16_t rr_timeout_ms = 150;
    static const std::uint16_t rr_retires_ms = 100;

    everest::lib::io::udp::udp_payload pl = make_ping_command();
    auto result = m_udp.request_reply(pl, rr_timeout_ms, rr_retires_ms, m_abort_requested).has_value();
    utilities::print_error(m_config.cb, "FIRMWARE", not result) << connection_result_message(result) << std::endl;
    return result;
}

std::string sync_fw_updater::connection_result_message(bool connected) const {
    if (connected) {
        return "ChargeBride Connected";
    }
    if (is_abort_requested()) {
        return "Connection check to ChargeBridge aborted on request";
    }
    return "No connection to ChargeBridge";
}

bool sync_fw_updater::ping() {
    everest::lib::io::udp::udp_payload pl = make_ping_command();

    return m_udp.request_reply(pl, m_abort_requested).has_value();
}

bool sync_fw_updater::check_reply(utilities::sync_udp_client::reply const& val) {
    if (val && val->size() == (sizeof(AppUDPResponse) + 2)) {
        AppUDPResponse reply;
        memcpy(&reply, val->buffer.data() + 2, sizeof(AppUDPResponse));
        return (reply == AppUDPResponse::AUR_Ok);
    }
    return false;
}

bool sync_fw_updater::upload_fw() {
    utilities::print_error(m_config.cb, "FIRMWARE", 0) << "Upload in progress" << std::endl;

    bool aborted = false;
    if (not upload_firmware(aborted)) {
        if (aborted) {
            utilities::print_error(m_config.cb, "FIRMWARE", 1)
                << "Upload of firmware image aborted on request" << std::endl;
        } else {
            utilities::print_error(m_config.cb, "FIRMWARE", 1) << "Upload of firmware image: " << std::endl;
        }
        return false;
    }

    utilities::print_error(m_config.cb, "FIRMWARE", 0) << "Upload completed" << std::endl;
    return true;
}

bool sync_fw_updater::upload_firmware(bool& aborted) {
    auto path = m_config.fw_path;
    utilities::print_error(m_config.cb, "FIRMWARE", 0) << path << std::endl;

    if (not fs::exists(path) || not fs::is_regular_file(path)) {
        utilities::print_error(m_config.cb, "FIRMWARE", 1) << "firmware file not found: " << path << std::endl;
        return false;
    }

    // Bail out before the device is put into firmware-update mode at all.
    if (is_abort_requested()) {
        aborted = true;
        return false;
    }

    std::uint32_t offset;
    charge_bridge::filesystem_utils::CryptSignedHeader hdr;

    if (not upload_init(path, offset, hdr)) {
        aborted = is_abort_requested();
        return false;
    }

    std::uint32_t total_bytes = 0;
    std::uint16_t sector = 0;

    if (not upload_transfer(path, sector, offset, total_bytes, aborted)) {
        if (aborted) {
            utilities::print_error(m_config.cb, "FIRMWARE", 1) << "Upload aborted at sector: " << sector << std::endl;
            return false;
        }
        utilities::print_error(m_config.cb, "FIRMWARE", 1) << "Upload failed at sector: " << sector << std::endl;
        return false;
    }
    // No cancellation point between the last chunk and upload_finish(): the image is fully
    // transferred by then and finishing takes seconds, while aborting here would throw away a
    // multi-minute transfer without any benefit.

    if (not upload_finish(path, total_bytes, hdr)) {
        return false;
    }

    return true;
}

/*
# File format for the binary update bundle:
# 32 byte header [reserved]
# 1 byte length of signature
# signature binary
# 1 byte NUM_SECTORS: This is the number of secure sectors
# 16 byte IV
# ... rest of the file is assembled firmware image: secure part...padding...non secure part (encrypted)
*/

bool sync_fw_updater::upload_init(const fs::path& file_path, std::uint32_t& offset,
                                  charge_bridge::filesystem_utils::CryptSignedHeader& hdr) {
    everest::lib::io::udp::udp_payload payload;

    if (not read_crypt_signed_header(file_path, hdr, offset)) {
        utilities::print_error(m_config.cb, "FIRMWARE", 1)
            << "Could not read header for file: " << file_path << std::endl;
        return false;
    }

    utilities::print_error(m_config.cb, "FIRMWARE", 0)
        << "Loaded firmware version file: " << file_path << " Version: " << hdr.firmware_version << std::endl;

    CbManagementPacket<CbFirmwareStart> msg;
    msg.type = CbStructType::CST_CbFirmwareStart;

    msg.data.is_secure_fw = true;
    msg.data.requires_crc_verification = true;
    msg.data.requires_sha256_verification = true;
    msg.data.requires_signature_verification = true;
    msg.data.requires_decryption = true;

    // Copy the IV from the header
    std::memcpy(msg.data.iv, hdr.iv.data(), sizeof(msg.data.iv));

    utilities::struct_to_vector(msg, payload.buffer);
    auto result = m_udp.request_reply(payload, m_abort_requested);

    return check_reply(result);
}

bool sync_fw_updater::upload_transfer(const fs::path& file_path, std::uint16_t& sector, std::uint32_t offset,
                                      std::uint32_t& total_bytes, bool& aborted) {
    bool send_failed = false;

    std::ifstream file(file_path, std::ios::binary);

    if (!file) {
        return false;
    }

    // Skip the header
    file.seekg(offset, std::ios::beg);

    bool processed_file = filesystem_utils::process_file(
        file, sub_chunk_size, [&](const std::vector<std::uint8_t>& buffer, bool last_chunk) -> bool {
            // Cancellation point of the whole upload: this loop runs for minutes, and the caller
            // (shutdown) must not have to wait for it. Leaving without the finish packet keeps the
            // device on its current firmware, so an aborted upload is just a failed upload.
            if (is_abort_requested()) {
                aborted = true;
                return true; // Interrupt
            }

            total_bytes += buffer.size();

            // Care must be taken when sending this over, since on the
            // receiving end we must remove the PKCS#7 added bytes
            auto block = make_fw_chunk(sector, last_chunk, buffer);
            auto result = m_udp.request_reply(block, m_abort_requested);

            if (not check_reply(result)) {
                // A chunk whose retries were cut short by the abort check is a cancellation, not a
                // transfer error: report it as such and leave the finish packet unsent either way.
                if (is_abort_requested()) {
                    aborted = true;
                    return true; // Interrupt
                }
                utilities::print_error(m_config.cb, "FIRMWARE", 1) << "chunk could not be sent" << std::endl;

                send_failed = true;
                return true; // Interrupt
            }

            sector++;

            return false; // Continue
        });

    return (processed_file) && (send_failed == false) && (aborted == false);
}

bool sync_fw_updater::upload_finish([[maybe_unused]] const fs::path& file_path, std::uint32_t total_bytes,
                                    const charge_bridge::filesystem_utils::CryptSignedHeader& hdr) {
    CbManagementPacket<CbFirmwareEnd> fw_check_packet;

    fw_check_packet.type = CbStructType::CST_CbFirmwareFinish;
    fw_check_packet.data.firmware_len = total_bytes;
    fw_check_packet.data.watermark_secure_end = hdr.num_sectors;

    if (hdr.sig_len > sizeof(fw_check_packet.data.fw_signature) || hdr.sig_len > hdr.signature.size()) {
        return false;
    }
    memcpy(fw_check_packet.data.fw_signature, hdr.signature.data(), hdr.sig_len);
    fw_check_packet.data.fw_signature_len = hdr.sig_len;

    udp_payload payload;
    utilities::struct_to_vector(fw_check_packet, payload.buffer);

    // The final check can be a very slow operation due to the cryptography involved.
    // Deliberately no abort check here: the image is on the device already and interrupting the
    // finish handshake would leave it with a half-committed update (see upload_firmware()).
    static const std::uint16_t rr_timeout_ms = 10000;
    static const std::uint16_t rr_retires_ms = 1;
    auto result = m_udp.request_reply(payload, rr_timeout_ms, rr_retires_ms);

    return check_reply(result);
}

udp_payload sync_fw_updater::make_fw_chunk(std::uint16_t sector, std::uint8_t last_chunk,
                                           std::vector<std::uint8_t> const& data) {
    CbManagementPacket<CbFirmwarePacket> fw_data_packet;
    fw_data_packet.type = CbStructType::CST_CbFirmwarePacket;
    fw_data_packet.data.last_packet = last_chunk;
    fw_data_packet.data.sector = sector;
    fw_data_packet.data.data_len = data.size();
    std::memcpy(fw_data_packet.data.data, data.data(), data.size());

    udp_payload result;
    utilities::struct_to_vector(fw_data_packet, result.buffer);

    return result;
}

} // namespace charge_bridge::firmware_update
