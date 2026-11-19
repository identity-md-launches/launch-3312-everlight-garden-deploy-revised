# Third-party provenance

The application and its dependencies come from the pinned Everlight source revision. [Baseline commit](https://github.com/identity-md-launches/launch-3281-everlightgarden-everlighttreasury-everli/tree/f3ae2915b2fc99c56079da2fc9addef2e94397e0)

| Component | Use and provenance |
| --- | --- |
| OpenZeppelin Contracts v5.2.0 | MIT. Ownership handoff, reentrancy guard, token calls and checked casts. [Vendored source notice](../lib/openzeppelin-contracts/VENDORED.md) |
| forge-std v1.9.7 | MIT/Apache-2.0. Foundry test framework. [Vendored source notice](../lib/forge-std/VENDORED.md) |
| LayerZero V2 / IMD OFT ABI | The bridge uses the baseline's exact ABI tuples, packet format and options. [Bridge definitions](../src/bridge/IMDBridge.sol) |
| Runtime fixtures | Byte-for-byte Ethereum IMD, Base IMD and Base adapter runtime from the baseline, exercised with test storage. Upstream token and adapter licensing applies separately. [Source verification references and hashes](evidence/bridge-dependencies.json) |
