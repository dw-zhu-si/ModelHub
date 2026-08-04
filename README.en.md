# ModelHub

English · [简体中文](README.md)

ModelHub is a native macOS model API gateway. It presents one local OpenAI-compatible endpoint for multiple providers, stable model aliases, health-aware routing, failover, budgets, usage analytics, and native media protocols.

## Highlights

- OpenAI-compatible chat and Responses endpoints, including incremental SSE streaming, tools, and multimodal payloads.
- Native image, video, speech, transcription, embedding, reranking, and provider-specific passthrough endpoints.
- Priority failover, round-robin, weighted-random, latency, stability, cost, context, and balanced routing strategies.
- Quarantined or unavailable models are excluded from normal routing and `/v1/models`; an explicit test can probe quarantined chat models again.
- Provider API keys and gateway tokens live in macOS Keychain. Background reads never request interactive authorization.
- Loopback-only service on `127.0.0.1:11435`, menu-bar background mode, launch at login, and a credential-free WidgetKit status widget.
- Read-only local MCP, A2A, and ACP surfaces protected by a separate Agent token.
- Eleven interface languages: Simplified Chinese, Traditional Chinese, English, Japanese, Korean, Spanish, French, German, Brazilian Portuguese, Russian, and Arabic.

## Build

Requirements: macOS 14 or later and Xcode 16 or later.

```bash
swift test --scratch-path .build/tests
./scripts/package_app.sh release
open ./dist/ModelHub.app
```

The packaging script produces a Universal arm64/x86_64 app and ZIP. Local builds are ad-hoc signed by default. Developer ID notarization and Mac App Store signing require the corresponding Apple identities and provisioning profiles.

## Quick start

1. Add a provider, API key, and model names in **Model Providers**.
2. Run an explicit model test if needed. Testing chat models can make a real provider request; media models are not automatically generated.
3. Create a stable alias in **Model Routes**.
4. Copy the endpoint and gateway token from **Service Settings**.
5. Set your client's Base URL to `http://127.0.0.1:11435/v1`.

```bash
curl http://127.0.0.1:11435/v1/chat/completions \
  -H "Authorization: Bearer YOUR_MODELHUB_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "smart",
    "messages": [{"role": "user", "content": "Hello"}],
    "stream": false
  }'
```

The full API contract is in [openapi/modelhub-openapi.yaml](openapi/modelhub-openapi.yaml).

## Privacy and security

ModelHub does not operate a cloud account service. Configuration, health records, and aggregated usage remain on the device by default. Requests are sent directly to the provider selected and configured by the user. Logs do not store API keys, prompts, or model response bodies.

Never include credentials in an issue. See [SECURITY.md](SECURITY.md) for private reporting instructions.

## License and acknowledgements

ModelHub is licensed under [Apache License 2.0](LICENSE). Its native routing, resilience, budget, context, protocol, and local agent feature set was informed by the MIT-licensed [OmniRoute](https://github.com/diegosouzapw/OmniRoute) project. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
