#!/usr/bin/env bash
set -euo pipefail

# Create 7 draft PRs against upstream RReverser/ascom-alpaca-rs
# Run from the repo root with: bash create-draft-prs.sh
# Requires: gh auth login (with permission to create PRs on your fork)

UPSTREAM="RReverser/ascom-alpaca-rs"
FORK_OWNER="ivonnyssen"

echo "=== 1/7: pr/switch-cancel-async ==="
gh pr create --draft --repo "$UPSTREAM" \
  --head "$FORK_OWNER:pr/switch-cancel-async" \
  --base main \
  --title "Add cancel_async method to Switch trait" \
  --body "$(cat <<'EOF'
## Summary

Adds the missing `cancel_async` method to the `Switch` trait for ISwitchV3 compliance. The method follows the same pattern as the existing `set_async` and `set_async_value` methods — default implementation returns `NOT_IMPLEMENTED`.

## Motivation

The ISwitchV3 specification defines `CancelAsync` as a required method, but the trait currently only has `set_async`, `set_async_value`, and `state_change_complete`. Adding `cancel_async` completes the ISwitchV3 surface and allows implementations to pass ConformU conformance testing for switches with async operations.

## Changes

- `src/api/switch.rs`: Added `cancel_async(&self, id: usize) -> ASCOMResult<()>` with `#[http("cancelasync", method = Put)]` attribute and default `NOT_IMPLEMENTED` implementation.

## Test plan

- [x] `cargo clippy` passes (full CI feature matrix verified)
- [ ] Existing switch tests continue to pass
- [ ] Method signature matches [ASCOM ISwitchV3 spec](https://ascom-standards.org/api/#/Switch%20Specific%20Methods/put_switch__device_number__cancelasync)
EOF
)"

echo "=== 2/7: pr/expose-into-router ==="
gh pr create --draft --repo "$UPSTREAM" \
  --head "$FORK_OWNER:pr/expose-into-router" \
  --base main \
  --title "Make Server::into_router() public for TLS support" \
  --body "$(cat <<'EOF'
## Summary

Changes `Server::into_router()` from `fn` to `pub fn`, allowing consumers to obtain the underlying `axum::Router` and handle socket binding and TLS wrapping themselves.

## Motivation

The current API only exposes `Server::listen()` and `Server::bind()`, both of which bind to a plain TCP socket internally. For TLS termination at the Alpaca server (e.g. using `axum-server` with `rustls`), consumers need access to the router so they can wrap it in their own `axum_server::bind_rustls()` call without duplicating the entire route setup.

## Changes

- `src/server/mod.rs`: Changed `fn into_router(self) -> Router` to `pub fn into_router(self) -> Router` and added documentation explaining the use case. The caller is responsible for starting the discovery server separately if needed.

## Test plan

- [x] `cargo clippy` passes (full CI feature matrix verified)
- [ ] Existing server tests continue to pass
- [ ] No breaking changes — this only widens visibility
EOF
)"

echo "=== 3/7: pr/client-custom-reqwest ==="
gh pr create --draft --repo "$UPSTREAM" \
  --head "$FORK_OWNER:pr/client-custom-reqwest" \
  --base main \
  --title "Add Client::new_with_client() for custom reqwest::Client" \
  --body "$(cat <<'EOF'
## Summary

Adds `Client::new_with_client(base_url, reqwest::Client)` as a companion to the existing `Client::new(base_url)`, allowing callers to inject a pre-configured `reqwest::Client`.

## Motivation

When connecting to an Alpaca server behind TLS with a private CA, the default `reqwest::Client` rejects the certificate. Callers need to inject a client configured with `.add_root_certificate(ca)`. Similarly, servers requiring HTTP Basic Auth need default headers set on the client. There is currently no way to customize the HTTP client used by the Alpaca `Client`.

## Changes

- `src/client/mod.rs`:
  - Added `http: reqwest::Client` field to `RawClient`
  - Added `RawClient::new_with_client()` constructor; existing `new()` delegates to it with the default global client
  - Changed `request()` to use `self.http` instead of the global `REQWEST` static
  - Added public `Client::new_with_client()` that wraps the raw client constructor
  - Updated `sub_client()` to clone the `http` field

## Test plan

- [x] `cargo clippy` passes (full CI feature matrix verified)
- [ ] Existing client tests continue to pass
- [ ] `Client::new()` behavior is unchanged (uses default client)
- [ ] No breaking changes — new additive API only
EOF
)"

echo "=== 4/7: pr/integer-parameter-handling ==="
gh pr create --draft --repo "$UPSTREAM" \
  --head "$FORK_OWNER:pr/integer-parameter-handling" \
  --base main \
  --title "Custom integer deserializer: INVALID_VALUE for out-of-range, i64 for uint32 support" \
  --body "$(cat <<'EOF'
## Summary

Replaces the generic `serde_plain::from_str` integer parsing with a custom ALPACA-aware deserializer that:

1. Parses integer parameters as i64 first, then narrows to the target type
2. Returns ASCOM `INVALID_VALUE` (error 1025) for values that parse but are out of range
3. Returns HTTP 400 `BadParameter` only for genuinely unparseable input
4. Special-cases `usize` index parameters to return `INVALID_VALUE` for negative values

Closes RReverser/ascom-alpaca-rs#5

## Motivation

**INVALID_VALUE vs BadRequest (issue #5):** The current implementation maps all integer deserialization failures to `BadParameter` (HTTP 400). The ASCOM Alpaca spec and ConformU conformance tests require that parseable values which are out of range for the target type return `INVALID_VALUE` (HTTP 200, error 1025) instead. For example, sending `Id=999` to a switch with only 4 ports should return `INVALID_VALUE`, not a 400.

**uint32 overflow:** `ClientID` and `ClientTransactionID` are uint32 per spec, so values above i32::MAX (e.g. 2147483648) must parse successfully. The previous code used `serde_plain::from_str` which parses directly to the target type with no intermediate widening, so valid uint32 values were rejected. Using i64 as the intermediate type covers the full uint32 range.

## How it works

The existing specialization block in `params.rs` (which already had special paths for `String` and `bool`) is extended with a custom `AlpacaDeserializer` for integers. The deserializer:

1. Parses the raw string as `i64` — if this fails, it's a `BadFormat` → HTTP 400
2. Attempts `T::try_from(i64_value)` — if this fails, it's `OutOfRange` → ASCOM `INVALID_VALUE`
3. On success, visits the appropriate serde integer method

## Changes

- `src/server/params.rs`:
  - Added `AlpacaParseError` enum with `BadFormat` and `OutOfRange` variants
  - Added `AlpacaDeserializer` implementing serde `Deserializer` with all integer visitor methods (i8 through u64)
  - Special-cases `usize` parameters to return `InvalidValue` for negative values
  - Comprehensive test suite covering parse errors, range errors, and edge cases
- `src/server/error.rs`: Added `ParameterOutOfRange` variant with i64 value
- `src/server/response.rs`: Maps `ParameterOutOfRange` to ASCOM `INVALID_VALUE` response

## Test plan

- [x] `cargo clippy` passes (full CI feature matrix verified)
- [ ] New unit tests in params.rs pass
- [ ] Integer parse errors return HTTP 400
- [ ] Integer range errors return ASCOM INVALID_VALUE (1025)
- [ ] uint32 values (e.g. 2147483648) parse successfully for u32 targets
- [ ] Negative index values return INVALID_VALUE, not 400
EOF
)"

echo "=== 5/7: pr/conformu-settings-file ==="
gh pr create --draft --repo "$UPSTREAM" \
  --head "$FORK_OWNER:pr/conformu-settings-file" \
  --base main \
  --title "Add builder pattern for ConformU test configuration" \
  --body "$(cat <<'EOF'
## Summary

Adds `ConformUTestBuilder` that allows configuring ConformU test parameters via a settings file, enabling customization of test delays and other options.

## Motivation

ConformU tests for switch devices are slow with the default `SwitchReadDelay` and `SwitchWriteDelay` values. In CI, this adds up significantly. A settings file can override these delays to speed up test runs, but the existing `run_conformu_tests` function provides no way to pass one.

## API

The existing function-based API remains unchanged. The new builder API:

```rust
conformu_tests::<dyn Switch>(url, 0)?
    .settings_file("conformu-fast.json")
    .run()
    .await?;
```

## Changes

- `src/server/test.rs`: Added `ConformUTestBuilder` with `settings_file()` method and `run()` async method. The existing `run_conformu_tests` function delegates to the builder internally.
- `src/test/mod.rs`: Re-export path update.

## Test plan

- [x] `cargo clippy` passes (full CI feature matrix verified)
- [ ] Existing `run_conformu_tests` behavior unchanged
- [ ] Builder with `.settings_file()` passes the `--settings-file` flag to ConformU
EOF
)"

echo "=== 6/7: pr/macos-compilation-fix ==="
gh pr create --draft --repo "$UPSTREAM" \
  --head "$FORK_OWNER:pr/macos-compilation-fix" \
  --base main \
  --title "Replace netdev with if-addrs to fix macOS compilation" \
  --body "$(cat <<'EOF'
## Summary

Replaces the `netdev` dependency with `if-addrs` to fix a trait recursion overflow that prevents compilation on macOS.

## Problem

`netdev` transitively depends on `objc2`, which defines a blanket `IntoIterator` impl for `&Retained<T>`. This causes infinite trait recursion when the Rust trait solver evaluates `serde_ndim`'s `NDim: IntoIterator` bound during compilation of the camera image array serialization code. This is a known Rust compiler issue ([rust-lang/rust#136856](https://github.com/rust-lang/rust/issues/136856)).

## Solution

`if-addrs` provides the same network interface enumeration functionality using only `libc` (unix) / `windows-sys` (windows) — no objc2 dependency chain. This eliminates the root cause entirely.

The main adaptation is a `GroupedInterface` struct that re-groups `if-addrs`' per-address entries by interface name, since `if-addrs` returns one entry per address while the discovery code expects one entry per interface.

## Motivation

This blocks running CI on macOS. The crate does not compile on macOS at all with the current `netdev` dependency.

## Changes

- `Cargo.toml`: Replace `netdev` with `if-addrs`
- `src/discovery.rs`: Add `GroupedInterface` struct with `get_active_interfaces()` function
- `src/client/discovery.rs`: Adapt to `GroupedInterface` API
- `src/server/discovery.rs`: Adapt to `GroupedInterface` API, improve multi-homed network handling
- `Cargo.lock`: Updated

## Test plan

- [x] `cargo clippy` passes (full CI feature matrix verified on Linux)
- [ ] Compiles on macOS
- [ ] Discovery still works on multi-homed hosts
- [ ] Loopback interfaces correctly excluded from discovery
EOF
)"

echo "=== 7/7: pr/optional-discovery-server ==="
gh pr create --draft --repo "$UPSTREAM" \
  --head "$FORK_OWNER:pr/optional-discovery-server" \
  --base main \
  --title "Make discovery server optional via Option<u16> port" \
  --body "$(cat <<'EOF'
## Summary

Changes `Server`'s discovery port from `u16` to `Option<u16>`, allowing the discovery server to be disabled entirely by passing `None`. Also makes `DEFAULT_DISCOVERY_PORT` public so consumers can reference it.

## Motivation

When running multiple Alpaca servers in integration tests, each server tries to bind the discovery UDP socket, causing port conflicts. Making the discovery server optional allows test servers to skip discovery binding entirely, avoiding these conflicts.

## Changes

- `src/server/mod.rs`:
  - `Server::discovery_port` changed from `u16` to `Option<u16>`
  - `BoundServer::discovery` changed from `BoundDiscoveryServer` to `Option<BoundDiscoveryServer>`
  - `BoundServer::discovery_listen_addr()` returns `Option<SocketAddr>`
  - `BoundServer::start()` restructured to handle both cases
- `src/discovery.rs`: `DEFAULT_DISCOVERY_PORT` changed from `pub(crate)` to `pub` with documentation

## Test plan

- [x] `cargo clippy` passes (full CI feature matrix verified)
- [ ] `Server::new(...)` with `Some(port)` behaves identically to before
- [ ] `Server::new(...)` with `None` skips discovery server entirely
- [ ] `DEFAULT_DISCOVERY_PORT` accessible from downstream crates
EOF
)"

echo ""
echo "All 7 draft PRs created!"
