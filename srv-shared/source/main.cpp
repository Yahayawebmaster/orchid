/* Orchid - WebRTC P2P VPN Market (on Ethereum)
 * Copyright (C) 2017-2019  The Orchid Authors
*/

/* GNU Affero General Public License, Version 3 {{{ */
/*
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.

 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.

 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
**/
/* }}} */


#include <cstdio>
#include <iostream>
#include <mutex>

#include <unistd.h>

#include <boost/filesystem/string_file.hpp>

#include <boost/program_options/parsers.hpp>
#include <boost/program_options/options_description.hpp>
#include <boost/program_options/variables_map.hpp>

#include <openssl/base.h>
#include <openssl/pkcs12.h>

#include <pc/webrtc_sdp.h>
#include <rtc_base/message_digest.h>
#include <rtc_base/openssl_identity.h>
#include <rtc_base/ssl_fingerprint.h>

#include "baton.hpp"
#include "beast.hpp"
#include "channel.hpp"
#include "client.hpp"
#include "egress.hpp"
#include "jsonrpc.hpp"
#include "local.hpp"
#include "locator.hpp"
#include "task.hpp"
#include "trace.hpp"
#include "transport.hpp"

namespace bssl {
    BORINGSSL_MAKE_DELETER(PKCS12, PKCS12_free)
    BORINGSSL_MAKE_STACK_DELETER(X509, X509_free)
}

namespace orc {

namespace po = boost::program_options;

class Node final {
  private:
    std::vector<std::string> ice_;

    Locator locator_;
    Address lottery_;

    S<Egress> egress_;

    std::mutex mutex_;
    std::map<std::string, W<Client>> clients_;

  public:
    Node(std::vector<std::string> ice, const std::string &rpc, Address lottery) :
        ice_(ice),
        locator_(Locator::Parse(rpc)),
        lottery_(std::move(lottery))
    {
    }

    S<Egress> &Wire() {
        return egress_;
    }

    S<Client> Find(const std::string &fingerprint) {
        std::unique_lock<std::mutex> lock(mutex_);
        auto &cache(clients_[fingerprint]);
        if (auto client = cache.lock())
            return client;
        auto client(Make<Sink<Client>>(locator_, lottery_));
        client->Wire<Translator>(egress_);
        client->self_ = client;
        cache = client;
        return client;
    }

    void Run(uint16_t port, const std::string &path, const std::string &key, const std::string &chain, const std::string &params) {
        boost::asio::ssl::context context{boost::asio::ssl::context::tlsv12};

        context.set_options(
            boost::asio::ssl::context::default_workarounds |
            boost::asio::ssl::context::no_sslv2 |
            boost::asio::ssl::context::single_dh_use |
        0);

        context.use_certificate_chain(boost::asio::buffer(chain.data(), chain.size()));
        context.use_private_key(boost::asio::buffer(key.data(), key.size()), boost::asio::ssl::context::file_format::pem);
        context.use_tmp_dh(boost::asio::buffer(params.data(), params.size()));


        http::basic_router<SslHttpSession> router{std::regex::ECMAScript};

        router.post(path, [&](auto request, auto context) {
            Log() << request << std::endl;

            try {
                auto body(request.body());
                static int fingerprint_(0);
                std::string fingerprint(std::to_string(fingerprint_++));
                auto client(Find(fingerprint));

                auto offer(body);
                auto answer(Wait(client->Respond(offer, ice_)));

                Log() << std::endl;
                Log() << "^^^^^^^^^^^^^^^^" << std::endl;
                Log() << offer << std::endl;
                Log() << "================" << std::endl;
                Log() << answer << std::endl;
                Log() << "vvvvvvvvvvvvvvvv" << std::endl;
                Log() << std::endl;

                context.send(Response(request, "text/plain", answer));
            } catch (...) {
                context.send(Response(request, "text/plain", "", boost::beast::http::status::not_found));
            }
        });

        router.all(R"(^.*$)", [&](auto request, auto context) {
            Log() << request << std::endl;
            context.send(Response(request, "text/plain", ""));
        });

        auto fail([](auto code, auto from) {
            Log() << "ERROR " << code << " " << from << std::endl;
        });

        HttpListener::launch(Context(), {
            asio::ip::make_address("0.0.0.0"),
            port
        }, [&](auto socket) {
            SslHttpSession::handshake(context, std::move(socket), router, [](auto context) {
                context.recv();
            }, fail);
        }, fail);

        Thread().join();
    }
};

std::string Stringify(bssl::UniquePtr<BIO> bio) {
    char *data;
    // BIO_get_mem_data is an inline macro with a char * cast
    // NOLINTNEXTLINE (cppcoreguidelines-pro-type-cstyle-cast)
    size_t size(BIO_get_mem_data(bio.get(), &data));
    return {data, size};
}

int Main(int argc, const char *const argv[]) {
    po::variables_map args;

    po::options_description options("command-line (only)");
    options.add_options()
        ("help", "produce help message")
    ;

    po::options_description configs("command-line / file");
    configs.add_options()
        ("dh", po::value<std::string>(), "diffie hellman params (pem encoded)")
        ("rpc", po::value<std::string>()->default_value("http://127.0.0.1:8545/"), "ethereum json/rpc private API endpoint")
        ("eth-lottery", po::value<std::string>()->default_value(""), "ethereum contract address of lottery")
        ("stun", po::value<std::string>()->default_value("stun:stun.l.google.com:19302"), "stun server url to use for discovery")
        ("host", po::value<std::string>(), "hostname to access this server")
        ("port", po::value<uint16_t>()->default_value(8443), "port to advertise on blockchain")
        ("path", po::value<std::string>()->default_value("/"), "path of internal https endpoint")
        ("tls", po::value<std::string>(), "tls keys and chain (pkcs#12 encoded)")
        ("ovpn-file", po::value<std::string>(), "openvpn .ovpn configuration file")
        ("ovpn-user", po::value<std::string>()->default_value(""), "openvpn credential (username)")
        ("ovpn-pass", po::value<std::string>()->default_value(""), "openvpn credential (password)")
    ;

    po::options_description hiddens("you can't see these");
    hiddens.add_options()
    ;

    po::store(po::parse_command_line(argc, argv, po::options_description()
        .add(options)
        .add(configs)
        .add(hiddens)
    ), args);

    if (auto path = getenv("ORCHID_CONFIG"))
        po::store(po::parse_config_file(path, po::options_description()
            .add(configs)
            .add(hiddens)
        ), args);

    po::notify(args);

    if (args.count("help") != 0) {
        std::cout << po::options_description()
            .add(options)
            .add(configs)
        << std::endl;

        return 0;
    }


    Initialize();

    std::vector<std::string> ice;
    ice.emplace_back(args["stun"].as<std::string>());


    std::string params;

    if (args.count("dh") == 0)
        params =
            "-----BEGIN DH PARAMETERS-----\n"
            "MIIBCAKCAQEA///////////JD9qiIWjCNMTGYouA3BzRKQJOCIpnzHQCC76mOxOb\n"
            "IlFKCHmONATd75UZs806QxswKwpt8l8UN0/hNW1tUcJF5IW1dmJefsb0TELppjft\n"
            "awv/XLb0Brft7jhr+1qJn6WunyQRfEsf5kkoZlHs5Fs9wgB8uKFjvwWY2kg2HFXT\n"
            "mmkWP6j9JM9fg2VdI9yjrZYcYvNWIIVSu57VKQdwlpZtZww1Tkq8mATxdGwIyhgh\n"
            "fDKQXkYuNs474553LBgOhgObJ4Oi7Aeij7XFXfBvTFLJ3ivL9pVYFxg5lUl86pVq\n"
            "5RXSJhiY+gUQFXKOWoqsqmj//////////wIBAg==\n"
            "-----END DH PARAMETERS-----\n"
        ;
    else
        boost::filesystem::load_string_file(args["dh"].as<std::string>(), params);


    std::string key;
    std::string chain;

    if (args.count("tls") == 0) {
        auto pem(Certify()->ToPEM());

        key = pem.private_key();
        chain = pem.certificate();

        // XXX: generate .p12 file (for Nathan)
        std::cerr << key << std::endl;
        std::cerr << chain << std::endl;
    } else {
        bssl::UniquePtr<PKCS12> p12([&]() {
            std::string str;
            boost::filesystem::load_string_file(args["tls"].as<std::string>(), str);

            bssl::UniquePtr<BIO> bio(BIO_new_mem_buf(str.data(), str.size()));
            orc_assert(bio);

            return d2i_PKCS12_bio(bio.get(), nullptr);
        }());

        orc_assert(p12);

        bssl::UniquePtr<EVP_PKEY> pkey;
        bssl::UniquePtr<X509> x509;
        bssl::UniquePtr<STACK_OF(X509)> stack;

        std::tie(pkey, x509, stack) = [&]() {
            EVP_PKEY *pkey(nullptr);
            X509 *x509(nullptr);
            STACK_OF(X509) *stack(nullptr);
            orc_assert(PKCS12_parse(p12.get(), "", &pkey, &x509, &stack));

            return std::tuple<
                bssl::UniquePtr<EVP_PKEY>,
                bssl::UniquePtr<X509>,
                bssl::UniquePtr<STACK_OF(X509)>
            >(pkey, x509, stack);
        }();

        orc_assert(pkey);
        orc_assert(x509);

        key = Stringify([&]() {
            bssl::UniquePtr<BIO> bio(BIO_new(BIO_s_mem()));
            orc_assert(PEM_write_bio_PrivateKey(bio.get(), pkey.get(), nullptr, nullptr, 0, nullptr, nullptr));
            return bio;
        }());

        chain = Stringify([&]() {
            bssl::UniquePtr<BIO> bio(BIO_new(BIO_s_mem()));
            orc_assert(PEM_write_bio_X509(bio.get(), x509.get()));
            return bio;
        }());
    }


    // XXX: the return type of OpenSSLIdentity::FromPEMStrings should be changed :/
    // NOLINTNEXTLINE (cppcoreguidelines-pro-type-static-cast-downcast)
    //U<rtc::OpenSSLIdentity> identity(static_cast<rtc::OpenSSLIdentity *>(rtc::OpenSSLIdentity::FromPEMStrings(key, chain));

    rtc::scoped_refptr<rtc::RTCCertificate> certificate(rtc::RTCCertificate::FromPEM(rtc::RTCCertificatePEM(key, chain)));
    U<rtc::SSLFingerprint> fingerprint(rtc::SSLFingerprint::CreateFromCertificate(*certificate));
    std::cerr << fingerprint->GetRfc4572Fingerprint() << std::endl;


    std::string host;
    if (args.count("host") != 0)
        host = args["host"].as<std::string>();
    else
        host = boost::asio::ip::host_name();

    auto port(args["port"].as<uint16_t>());
    auto path(args["path"].as<std::string>());


    std::cerr << "url = " << fingerprint->algorithm << " " << fingerprint->GetRfc4572Fingerprint() << std::endl;
    std::cerr << "tls = " << "https://" << host << ":" << std::to_string(port) << path << std::endl;


    auto node(Make<Node>(std::move(ice), args["rpc"].as<std::string>(), Address(args["eth-lottery"].as<std::string>())));

    if (args.count("ovpn-file") != 0) {
        std::string ovpnfile;
        boost::filesystem::load_string_file(args["ovpn-file"].as<std::string>(), ovpnfile);

        auto username(args["ovpn-user"].as<std::string>());
        auto password(args["ovpn-pass"].as<std::string>());

        Spawn([&node, ovpnfile = std::move(ovpnfile), username = std::move(username), password = std::move(password)]() -> task<void> {
            auto egress(Make<Sink<Egress>>(0));
            co_await Connect(egress.get(), GetLocal(), 0, ovpnfile, username, password);
            node->Wire() = std::move(egress);
        });
    }


    node->Run(port, path, key, chain, params);
    return 0;
}

}

int main(int argc, const char *const argv[]) { try {
    return orc::Main(argc, argv);
} catch (const std::exception &error) {
    return 1;
} }
