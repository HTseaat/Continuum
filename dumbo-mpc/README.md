# AD-MPC: Asynchronous Dynamic MPC with Guaranteed Output Delivery

## Setup

1. Ensure that [Docker](https://docs.docker.com/) is installed and the daemon is running.

2. Move into the project root:
   ```bash
   cd dumbo-mpc
   ```

3. Build the Docker image:
   ```bash
   docker build -t dumbo-mpc:latest .
   ```
   > **Note:** If you are on macOS with Apple Silicon (M‑series) and need an `arm64` image, you can instead run  
   > ```bash
   > docker buildx build --platform=linux/arm64 -t dumbo-mpc:arm64 .
   > ```


## Running AD‑MPC locally

This section describes how to run a local AD‑MPC experiment and obtain **per‑layer trusted verification time** from the logs.

The overall flow is:

1. Generate dynamic node configuration files with `AsyRanTriGen`.
2. Run a local network experiment with `run_local_network_test.sh`.
3. Extract per‑layer `trusted_verification_time` using a helper script.

### 1. Enter the container

If you are not already inside the Docker container, start one from the built image:

```bash
docker run -it dumbo-mpc:latest bash
# or, if you use a prebuilt image:
# docker run -it htseaat/dumbo-mpc:admpc2.3 bash
```

All commands below are assumed to be executed **inside** the container.

### 2. Generate dynamic configuration (AsyRanTriGen)

First, move to the `AsyRanTriGen` subdirectory and run the dynamic key / configuration generation script:

```bash
cd dumbo-mpc/AsyRanTriGen

python3 scripts/run_key_gen_dyn.py \
  --N 4 \
  --f 1 \
  --layers 4 \
  --total_cm 100
```

Parameter meanings:

- `--N`: total number of nodes (e.g., `4`).
- `--f`: fault threshold (maximum number of Byzantine nodes tolerated), e.g., `4`.
- `--layers`: **total number of layers including input and output layers**.  
  The actual computation layers are:

  \[
  \text{computation\_layers} = \text{layers} - 2
  \]

  For `--layers 4`, this corresponds to `4 - 2 = 2` computation layers.
- `--total_cm`: total number of multiplication gates in the circuit, e.g., `100`.

This step generates all dynamic node configuration files needed for the subsequent local experiment.

### 3. Run the local network experiment

Return to the project root and launch the local AD‑MPC experiment:

```bash
cd ../..

./run_local_network_test.sh ad-mpc2 4 4 100
```

Here the arguments have the following meanings:

- `ad-mpc2`: protocol / experiment type to run  
  (in this example, a specific AD‑MPC variant named `ad-mpc2`).
- First `4`: **committee size** — the number of nodes in the committee.
- Second `4`: **number of layers** used by this experiment.  
  This should be consistent with the configuration you generated in step 2 (e.g., either the total layers or the number of computation layers, depending on how you define it for your experiments).
- `100`: controls the scale of the experiment  
  (e.g., number of repetitions / trials; you can interpret this as the number of runs over which timing information is collected).

The script will start the required processes and produce logs under the corresponding directories used by `AsyRanTriGen`.

### 4. Extract per‑layer trusted verification time

After the experiment finishes, run the following command to parse the logs and obtain **per‑layer trusted verification time**:

```bash
python3 dumbo-mpc/AsyRanTriGen/log/extract_trusted_time.py
```

This script scans the generated logs and extracts the `trusted_verification_time` for each layer, enabling **second‑level, per‑layer timing validation** of the protocol’s verification phase.

## Multi‑machine Deployment (Distributed Experiment)

This section describes how to run **distributed experiments across multiple machines**.

**AD‑MPC** and **Dumbo‑MPC** share the same cluster preparation steps:
- update `ip.txt` / `config.sh`
- distribute `ip.txt` to all servers

They diverge in:
- **how configs are generated** (AD‑MPC vs Dumbo‑MPC scripts)
- **how the protocol is launched** (`control-node.sh` vs `remote/.../launch_asyrantrigen.sh`)
- **whether `remote/ip.txt` must be kept in sync** (required by Dumbo‑MPC)

All commands below are assumed to be executed on a single **host controller machine** that can SSH into all servers.

---

### A. Shared cluster preparation (AD‑MPC + Dumbo‑MPC)

> Run this section **once** before running either AD‑MPC or Dumbo‑MPC.

#### A1. Configure IPs and node metadata (on the host)

On the host machine, go to:

```bash
cd dumbo-mpc/AsyRanTriGen/scripts
```

Edit:

- `ip.txt`
  - One IP per line; the **order defines the logical node index**.
  - Number of IPs must be ≥ the number of nodes you will run.
- `config.sh`
  - `NODE_NUM`: number of servers
  - `NODE_IPS`: list of IPs (same order as `ip.txt`), length ≥ `NODE_NUM`
  - `NODE_SSH_USERNAME`: SSH username (default `root`)

> Keep `NODE_NUM`, `NODE_IPS`, and the `N` used in config generation consistent.

#### A2. Set up passwordless SSH (optional but recommended)

```bash
cd dumbo-mpc/AsyRanTriGen/scripts
./setup_ssh_keys.sh <N>
```

#### A3. Distribute the updated `ip.txt` to all servers (from the host)

Whenever you change `ip.txt` on the host, push it to all servers:

```bash
cd dumbo-mpc/AsyRanTriGen/scripts
./distribute-admpc.sh
```

---

### B. AD‑MPC distributed experiment

This subsection describes how to run AD‑MPC across multiple remote servers.

#### B1. Generate per‑node JSON configuration files (on the host)

```bash
cd dumbo-mpc/AsyRanTriGen/scripts

python3 create_json_files.py <protocol> <N> <t> <layers> <total_cm> [--run-id RUN_ID]
```

This writes JSON files under:

```text
dumbo-mpc/AsyRanTriGen/conf/<protocol>_<total_cm>_<layers>_<N>/local.<id>.json
```

The directory name `<protocol>_<total_cm>_<layers>_<N>` is referred to as `<config_dir>` below.

#### B2. Distribute the generated AD‑MPC config directory to all servers (from the host)

```bash
cd dumbo-mpc/AsyRanTriGen/scripts
./distribute-file.sh
```

**Important:** `distribute-file.sh` is currently **hardcoded** to tar/scp a specific config directory name.
For example, in your current script it does:

- `tar Jcf mpc_4.tar.xz mpc_4`
- then scp/extract `mpc_4.tar.xz`

So before distributing, make sure the tar line matches the directory you just generated under:

```text
dumbo-mpc/AsyRanTriGen/conf/<your_config_dir>
```

#### B3. Start the distributed protocol on all nodes (from the host)

Use `control-node.sh`:

```bash
cd dumbo-mpc/AsyRanTriGen/scripts
./control-node.sh <config_dir> <protocol_override> [timeout]
```

Logs are typically written under:

```text
dumbo-mpc/AsyRanTriGen/scripts/logs/
```

#### B4. Extract trusted verification time from distributed logs (on the host)

```bash
cd dumbo-mpc/AsyRanTriGen/scripts
python3 extract_trusted_time.py
```

This produces:
- `trusted_times.csv`
- `trusted_times_layer_avg.csv`
- `trusted_times_overall_avg_trimmed.csv`

---

### C. Dumbo‑MPC distributed test (multi‑machine)

This subsection describes how to run **Dumbo‑MPC** across multiple remote servers.

> Assumes you have already completed **Section A** (cluster preparation + `ip.txt` distribution).

#### C1. Generate Dumbo‑MPC dynamic configuration (on the host)

Run the Dumbo‑MPC config generation script from the `AsyRanTriGen` directory:

```bash
cd dumbo-mpc/AsyRanTriGen

python3 scripts/run_key_gen_dumbo_dyn.py \
  --N 4 \
  --f 1 \
  --k 300 \
  --layers 6 \
  --ip-file scripts/ip.txt \
  --port 7001
```

Parameter meanings (based on `run_key_gen_dumbo_dyn.py`):

- `--N`: number of parties/nodes.
- `--f`: fault threshold (script asserts `N >= 3f + 1`).  
  The generated JSON uses `"t": f`.
- `--k`: **number of Beaver triples to generate**.  
  This should equal the **number of multiplication gates** in the whole circuit (i.e., `triples = #mul_gates`).
- `--layers`: number of circuit layers (stored into `extra.layers` in each node config).
- `--ip-file`: path to the IP list file. If omitted, defaults to `scripts/ip.txt` next to the script.
- `--port`: base peer port. The script writes `peers` as `"<ip>:<port>"` for all nodes.

#### C2. Distribute the generated Dumbo‑MPC config directory to all servers (from the host)

```bash
cd dumbo-mpc/AsyRanTriGen/scripts
./distribute-file.sh
```

**Important:** as noted in **B2**, `distribute-file.sh` is currently **hardcoded** to tar/scp a particular config directory
(e.g., `mpc_4`). Update the tar input/output name to match the config directory you just generated.

#### C3. Update `remote/ip.txt` (on the host)

Dumbo‑MPC also relies on an `ip.txt` under the `remote` folder. Keep its content/order consistent with `AsyRanTriGen/scripts/ip.txt`.

If your repository layout matches the default, you can sync it via:

```bash
cp dumbo-mpc/AsyRanTriGen/scripts/ip.txt dumbo-mpc/remote/ip.txt
```

#### C4. Launch Dumbo‑MPC (on the host)

Run the launcher under `remote/AsyRanTriGen_scripts`:

```bash
cd dumbo-mpc/remote/AsyRanTriGen_scripts
./launch_asyrantrigen.sh 4 300 6
```

Argument meanings:

- `4`: number of nodes (`N`)
- `300`: **number of triples** (i.e., number of multiplication gates; should match `--k` in C1)
- `6`: `layers` (must match `--layers` in C1)

#### C5. Expected behavior: `[BatchReconstruct] P1 Send` on some nodes

During Dumbo‑MPC runs, it is expected that some nodes appear to “stop” at log lines like:

```text
[BatchReconstruct] P1 Send
```


In our experiments, this happens because we intentionally make **node0 and node1 go offline during the 4th circuit layer**
(i.e., layer index `L == 3` if layers are 0-indexed in code). Therefore, only the remaining online nodes
(e.g., **node2 and node3** in a 4-node run) will continue and print lines like `[BatchReconstruct] P1 Send`.

**Where to find the logs:**
- Per-node logs are typically named like:
  - `dumbo-mpc/remote/AsyRanTriGen_scripts/logs/node<id>.log` (e.g., `node3.log`)

---


### Quick example (AD‑MPC): 4-node committee, depth-6 circuit (width 100, 1:1 mul/add)

As a concrete example, suppose we want to run a circuit with:
- committee size `N = 4`,
- depth `6` (computation layers),
- width `100` per layer,
- mul:add gate ratio `1:1`,
which corresponds to `layers = 8` (including input/output) and `total_cm = 300`.

1) Update `ip.txt` and `config.sh` (A1)  
2) Setup SSH keys (A2)  
3) Generate configs:

```bash
cd dumbo-mpc/AsyRanTriGen
python3 scripts/create_json_files.py admpc 4 1 8 300
```

4) Distribute `ip.txt` and configs:

```bash
cd dumbo-mpc/AsyRanTriGen/scripts
./distribute-admpc.sh
./distribute-file.sh
```

5) Start protocol:

```bash
cd dumbo-mpc/AsyRanTriGen/scripts
./control-node.sh admpc_300_8_4 admpc2
```

6) Extract trusted verification time:

```bash
cd dumbo-mpc/AsyRanTriGen/scripts
python3 extract_trusted_time.py
```

### Quick example (Dumbo‑MPC): 4 nodes, 300 triples, 6 layers

As a concrete example, suppose we want to run a **Dumbo‑MPC** multi-machine test with:

- `N = 4` nodes
- fault threshold `f = 1` (must satisfy `N >= 3f + 1`)
- `k = 300` Beaver triples (**equals the number of multiplication gates in the whole circuit**)
- `layers = 6`
- base peer port `7001`

1) Complete the shared cluster preparation (Section **A**):
   - update `AsyRanTriGen/scripts/ip.txt` and `config.sh`
   - run `./distribute-admpc.sh` to distribute `ip.txt`

2) Generate Dumbo‑MPC configs (on the host):

```bash
cd dumbo-mpc/AsyRanTriGen

python3 scripts/run_key_gen_dumbo_dyn.py --N 4 --f 1 --k 300 --layers 6 --ip-file scripts/ip.txt --port 7001
```

3) Distribute the generated config directory to all workers:

```bash
cd dumbo-mpc/AsyRanTriGen/scripts
./distribute-file.sh
```

> **Important:** `distribute-file.sh` is currently **hardcoded** to compress/copy a specific directory name
> (e.g., it runs `tar Jcf mpc_4.tar.xz mpc_4`).  
> Before running it, update the tar input/output name to match the config directory you just generated under:
> `dumbo-mpc/AsyRanTriGen/conf/`.

4) Keep `remote/ip.txt` in sync with `AsyRanTriGen/scripts/ip.txt`:

```bash
cp dumbo-mpc/AsyRanTriGen/scripts/ip.txt dumbo-mpc/remote/ip.txt
```

5) Launch Dumbo‑MPC (on the host):

```bash
cd dumbo-mpc/remote/AsyRanTriGen_scripts
./launch_asyrantrigen.sh 4 300 6
```

Where:
- `4` is `N`
- `300` is the **number of triples** (must match `--k`)
- `6` is `layers` (must match `--layers`)

6) Expected observation point in logs:

Because we intentionally make **node0 and node1 go offline during the 4th circuit layer**
(i.e., `L == 3` if layers are 0-indexed), only the remaining online nodes
(e.g., **node2 and node3** in a 4-node run) will continue and print lines like:

```text
[BatchReconstruct] P1 Send
```

**Logs location:**
- `dumbo-mpc/remote/AsyRanTriGen_scripts/logs/node<id>.log` (e.g., `node3.log`)


