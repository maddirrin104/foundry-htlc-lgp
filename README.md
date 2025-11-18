# HTLC Protocol Experiments & Comparison (MP-HTLC-LGP)

This repository contains the [Foundry](https://getfoundry.sh/) source code for deploying, testing, and running experiments on various Hash Time Lock Contract (HTLC) protocol variants.

## Objective

The primary goal of this repository is to conduct experiments and analysis on the proposed **MP-HTLC-LGP** protocol. Its performance, gas efficiency, and security properties are compared against other well-known HTLC implementations.

## Implemented Protocols

The Solidity smart contracts for the following protocols are available in the `src/` directory:

* **HTLC**: The basic Hash Time Lock Contract.
* **HTLC-GP**: HTLC with a Griefing-Penalty mechanism.
* **HTLC-GPZ**: (You can add a brief description of 'GPZ' here).
* **MP-HTLC**: Multi-Path HTLC protocol.
* **MP-HTLC-LGP**: The proposed Multi-Path HTLC with ... (your protocol's features) mechanism.

## Directory Structure

* `src/`: Contains all Solidity source code for the protocols.
* `script/`: Foundry scripts (`.s.sol`) for deployment and interaction simulations.
* `test/`: Protocol tests (unit tests and integration tests).
* `lib/`: Project dependencies (e.g., `foundry-dev-ops`, `solmate`).
* `poc/`: (Suggested) Location for detailed Proof-of-Concept (POC) and demo markdown files.

---

## Getting Started

### Prerequisites
* [**Foundry (Forge & Cast)**](https://getfoundry.sh/)

### Installation
1.  Clone the repository:
    ```bash
    git clone [YOUR_REPO_LINK]
    cd test-foundry
    ```

2.  Install dependencies:
    ```bash
    forge install
    ```

3.  Build the project:
    ```bash
    forge build
    ```

---

## Usage & Experiments

Each protocol has a dedicated script to demonstrate its workflow. These scripts are executed using `forge script`.

**Detailed instructions, specific CLI commands, and expected outcomes** for running each demo are documented in separate Markdown files.

Please refer to the following documents to run the experiments:

* **1. Basic HTLC:**
    * [📜 HTLC Demo Instructions](./PoC-CLI/HTLC.md)
* **2. HTLC-GP (Griefing-Penalty):**
    * [📜 HTLC-GP Demo Instructions](./PoC-CLI/HTLC-GP.md)
* **3. HTLC-GPZ:**
    * [📜 HTLC-GPZ Demo Instructions](./PoC-CLI/HTLC-GPZ.md)
* **4. MP-HTLC (Multi-Path):**
    * [📜 MP-HTLC Demo Instructions](./PoC-CLI/MP-HTLC.md)
* **5. MP-HTLC-LGP (Proposed Protocol):**
    * [📜 MP-HTLC-LGP Demo Instructions](./PoC-CLI/mp-htlc-lgp.md)

### Example

A general script execution command looks like this (please see the specific `*.md` files for exact commands):

```bash
# Example: Running the script for MP-HTLC-LGP
# (The actual command will be in your POC markdown file)

forge script script/MpGriefingPenalty.s.sol:MpGriefingPenaltyScript \
    --rpc-url $YOUR_RPC_URL \
    --private-key $YOUR_PRIVATE_KEY \
    --broadcast -vvvv
```

### Running Tests
> To run the full test suite for all contracts:
```bash
forge test
```

### Contributing
Vo Minh An 

### License
This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.