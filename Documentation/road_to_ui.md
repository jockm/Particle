# Road to UI: Serialized Nuklear Over High-Speed Serial

## 1. Overview and System Goals

This document outlines the architecture and implementation roadmap for building a cross-platform graphical user interface (GUI) system for an embedded multi-core target. All embedded cores share a single **1 Mbps serial link** (UART or USB-CDC) connected to a desktop host running **macOS, Windows, or Linux**.

### Key Requirements
* **Shared Physical Link:** Multiple independent cores transmit UI updates and receive user input over one 1 Mbps serial interface without packet collisions or interleaved command corruption.
* **Focused Input Routing:** User keyboard and mouse events from the desktop host are routed exclusively to the embedded core that currently holds input focus, managed through an internal multi-core adapter.
* **Low Embedded Footprint:** Minimal RAM, flash, and CPU overhead on the target cores, avoiding pixel rasterization or heavy windowing servers on the embedded side.
* **Native Cross-Platform Desktop Host:** Consistent window management, HiDPI rendering, and hardware-accelerated drawing across macOS, Windows, and Linux.

---

## 2. Why Serialized Nuklear

**Nuklear** is an immediate-mode GUI toolkit written in strict ANSI C (C89) contained in a single header file with zero external dependencies and no required dynamic memory allocation.

Instead of rendering pixels into a local framebuffer on each embedded core and streaming raw bitmaps over a bandwidth-constrained serial line, each core runs Nuklear up to the **draw-command generation stage**. The core converts its active widgets into a compact list of 2D rendering primitives (`nk_draw_command`)—rectangles, lines, triangles, scissor clip boxes, and font glyph quads—and streams those draw lists to the desktop host.

### Architectural Advantages
* **Deterministic Memory:** Each core uses fixed-size static buffers for Nuklear's context, command list, vertex buffer, and element index buffer.
* **Low Bandwidth Consumption:** A typical widget screen compiles to 2 KB–15 KB of draw data, easily sustaining smooth frame rates over a 1 Mbps (~100 KB/s usable throughput) serial link when paired with dirty-frame updates.
* **Native Host Rendering:** The desktop host replays the serialized draw lists using GPU-accelerated graphics APIs (via SDL2, Raylib, or OpenGL/Metal/Direct3D), providing crisp typography and native window focus events on macOS, Windows, and Linux.

---

## 3. System Architecture

```text
+-----------------------------------------------------------------------+
| Embedded Multi-Core System                                            |
|                                                                       |
|  +----------+                                                         |
|  |  Core 0  |----+                                                    |
|  +----------+    |     +-----------------------+                      |
|                  +---> | Internal Mux / Demux  |                      |
|  +----------+    |     | Adapter               |                      |
|  |  Core 1  |----+---> | - TX Packet Arbiter   | <==== 1 Mbps ====>   |
|  +----------+    |     | - RX Focus Dispatcher |       Serial Link    |
|                  |     | - Credit Flow Control |                      |
|  +----------+    |     +-----------------------+                      |
|  |  Core N  |----+                                                    |
|  +----------+                                                         |
+-----------------------------------------------------------------------+
                                                               ||
                                                               \/
+-----------------------------------------------------------------------+
| Cross-Platform Desktop Host (macOS / Windows / Linux)                 |
|                                                                       |
|  +-----------------------------------------------------------------+  |
|  | Serial Framing & Packet Router                                  |  |
|  +-----------------------------------------------------------------+  |
|         |                         |                         |         |
|         v                         v                         v         |
|  +-------------+           +-------------+           +-------------+  |
|  | OS Window 0 |           | OS Window 1 |           | OS Window N |  |
|  |  (Core 0)   |           |  (Core 1)   |           |  (Core N)   |  |
|  +-------------+           +-------------+           +-------------+  |
+-----------------------------------------------------------------------+
```

### Component Responsibilities
1. **Embedded Cores (0..N):** Run application logic and Nuklear UI definitions. Serialize draw lists into discrete packets and process incoming input events when focused.
2. **Internal Mux/Demux Adapter:** Arbitrates outgoing packets from multiple cores onto the single serial TX line and dispatches incoming input/control packets to the active core's RX queue.
3. **Desktop Host Application:** Opens the serial port, demultiplexes incoming draw streams into separate OS windows (one per `Core_ID`), renders primitives on the GPU, and forwards window focus and input events back to the target.

---

## 4. Wire Protocol and Packet Framing

Because multiple cores share one serial channel and binary draw lists contain arbitrary byte values, raw byte streams cannot be used directly. All traffic is encapsulated in **COBS (Consistent Overhead Byte Stuffing)** frames delimited by a `0x00` packet boundary byte.

### Frame Layout (Decoded Payload)

| Offset | Field | Size | Description |
| :--- | :--- | :--- | :--- |
| `0` | `Core_ID` | 1 Byte | Target or source core index (`0x00`–`0xFE`; `0xFF` = Broadcast) |
| `1` | `Msg_Type` | 1 Byte | Packet payload type identifier |
| `2` | `Seq_Num` | 1 Byte | Rolling sequence counter per core for drop detection |
| `3` | `Length` | 2 Bytes | Payload length in bytes (little-endian `uint16_t`) |
| `5` | `Payload` | `N` Bytes | Command, draw list, or input event data |
| `5 + N` | `CRC16` | 2 Bytes | CRC-16/CCITT checksum covering bytes `0` through `4 + N` |

### Message Types (`Msg_Type`)

#### Downstream (Embedded Cores -> Desktop Host)
* `0x01` **`MSG_HELLO`:** Announces core presence, display dimensions (`width`, `height`), and window title string.
* `0x02` **`MSG_FONT_ATLAS_REQ`:** Requests or negotiates standard font metrics shared between target and host.
* `0x03` **`MSG_DRAW_BEGIN`:** Marks the start of a new UI frame for `Core_ID` and clears the previous draw buffer.
* `0x04` **`MSG_DRAW_CHUNK`:** Carries serialized Nuklear vertices, element indices, and `nk_draw_command` entries.
* `0x05` **`MSG_DRAW_END`:** Signals frame completion, triggering the host window to swap buffers and present the frame.
* `0x06` **`MSG_CREDIT_REQ`:** Optional flow-control telemetry indicating queued outgoing frames.

#### Upstream (Desktop Host -> Embedded Cores)
* `0x81` **`MSG_FOCUS_EVENT`:** Notifies the internal adapter and core that `Core_ID` gained (`1`) or lost (`0`) window focus.
* `0x82` **`MSG_INPUT_MOUSE`:** Carries cursor coordinates (`x`, `y`), button states, and scroll wheel deltas.
* `0x83` **`MSG_INPUT_KEY`:** Carries key codes, press/release state, modifier flags, and UTF-8 text input runes.
* `0x84` **`MSG_REFRESH_ALL`:** Broadcast (`Core_ID = 0xFF`) sent when the host connects or reconnects, instructing all cores to emit a full UI frame.
* `0x85` **`MSG_CREDIT_GRANT`:** Grants transmission byte credits to a specific `Core_ID` to prevent serial buffer starvation.

---

## 5. Embedded Core Integration

### Static Memory Configuration
Each core initializes Nuklear using pre-allocated static memory blocks (`nk_init_fixed`) to guarantee deterministic footprint and zero heap fragmentation:
* **Context Buffer:** ~16 KB–32 KB per core (holds widget state and layout stacks).
* **Command Buffer:** ~16 KB per core (holds high-level draw commands prior to vertex conversion).
* **Vertex & Index Buffers:** ~32 KB per core (holds triangulated 2D geometry for serialization).

### Font Metric Synchronization
To keep serial bandwidth low, the embedded core does **not** transmit font bitmap textures over UART. Instead:
1. Both the embedded build and the desktop host embed the exact same font metric table (e.g., a standard monospace or clean sans-serif font baked with `stb_truetype` at build time).
2. The embedded core uses those metrics to calculate text bounding boxes and widget layouts accurately.
3. Text draw commands transmit only glyph indices or UTF-8 strings alongside screen coordinates, and the desktop host renders the glyphs directly from its local GPU font atlas.

### Event-Driven Frame Emission
Rather than streaming identical frames continuously at 60 Hz:
* Each core maintains a `ui_dirty` flag.
* The core runs a Nuklear frame pass and transmits `MSG_DRAW_BEGIN` -> `MSG_DRAW_CHUNK` -> `MSG_DRAW_END` only when an input event arrives for that core, an internal telemetry value changes, or `MSG_REFRESH_ALL` is received.

---

## 6. Internal Multi-Core Mux/Demux Adapter

The internal adapter sits between the cores' IPC/mailbox interfaces and the physical UART peripheral. It can run on a dedicated I/O core, a DMA-assisted interrupt service routine, or a lightweight RTOS task.

### Downstream Arbitration (TX Mux)
* **Packet-Atomic Scheduling:** Each core writes complete COBS-encoded frames into its dedicated per-core TX ring buffer. The adapter drains one complete packet from a core before switching to the next core (round-robin or priority-weighted), guaranteeing that frames from different cores never interleave on the wire.
* **Per-Core Bandwidth Credits:** To prevent a rapidly updating core from starving other cores on the 1 Mbps link, the adapter enforces a token bucket or credit counter per `Core_ID`.

### Upstream Dispatch (RX Demux & Focus Control)
* **Active Focus Register:** The adapter maintains an `active_focus_core_id` state variable.
* **Synchronized Focus Switching:**
  * When the user clicks Window `K` on the desktop host, the host emits `[Core_ID = K] [MSG_FOCUS_EVENT = 1]`. The adapter updates `active_focus_core_id = K` and forwards the focus notification to Core `K` (and `MSG_FOCUS_EVENT = 0` to the previously focused core).
  * If focus is changed internally on the embedded hardware (for example, via a physical button or a core-initiated hotkey), the adapter updates `active_focus_core_id` and sends a `MSG_FOCUS_EVENT` upstream so the desktop host brings the corresponding window to the foreground.
* **Input Filtering:** Incoming `MSG_INPUT_MOUSE` and `MSG_INPUT_KEY` packets are validated against `active_focus_core_id` and placed directly into that core's lock-free RX input ring buffer.

---

## 7. Cross-Platform Desktop Host Application

The desktop host is implemented in **C/C++ with SDL2** (or **Rust with `sdl2` / `winit` + `wgpu`**) so a single codebase compiles cleanly for macOS, Windows, and Linux.

### Host Responsibilities
1. **Serial I/O Thread:** Opens the OS serial device (`/dev/tty.*` on macOS, `COMx` on Windows, `/dev/ttyUSB*` or `/dev/ttyACM*` on Linux) at `1,000,000` baud with hardware flow control (`RTS/CTS`) if supported. Decodes COBS frames, verifies `CRC16`, and pushes parsed messages to the UI thread.
2. **Dynamic Window Management:** Upon receiving `MSG_HELLO` from a `Core_ID`, the host creates a dedicated native OS window titled `[Core N] <Window Title>` and maps the SDL `WindowID` to `Core_ID`.
3. **GPU Draw-List Replay:** Each window maintains a double-buffered command list. On `MSG_DRAW_END`, the host binds its local font atlas texture, applies `glScissor` / SDL clip rectangles per `nk_draw_command`, and draws the indexed triangle batches.
4. **Focus & Input Capture:**
   * `SDL_WINDOWEVENT_FOCUS_GAINED` triggers an immediate `MSG_FOCUS_EVENT` packet for the window's `Core_ID`.
   * Mouse motion, clicks, scroll events, and keyboard events inside the focused window are translated into Nuklear input events and transmitted upstream over the serial port.

---

## 8. Bandwidth Budget at 1 Mbps

At **1,000,000 bps** (8N1 UART framing = 10 bits per byte), the physical maximum throughput is **100,000 bytes/sec (~97.6 KB/s)**. After COBS framing and packet headers (~2% overhead), usable payload bandwidth is approximately **95 KB/s**.

| Workload Scenario | Approx. Frame Size | Active Cores | Target Update Rate | Bandwidth Used | Link Utilization |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Control Panel (Buttons, Sliders, Status)** | 3 KB | 4 cores | 5 Hz each | 60 KB/s | ~63% |
| **Interactive Core + Background Monitors** | 8 KB (active) / 1.5 KB (idle) | 1 active + 3 idle | 8 Hz active / 1 Hz idle | 68.5 KB/s | ~72% |
| **Single Core High-Rate Telemetry / Plot** | 6 KB | 1 active core | 15 Hz | 90 KB/s | ~95% |

### Bandwidth Optimization Techniques
* **Quantized Coordinates:** Pack 2D vertex positions as `int16_t` (0.25-pixel subpixel fixed-point) instead of `float32`, cutting vertex buffer size by 40%–50%.
* **Indexed Quads:** Use 16-bit vertex indices (`uint16_t`) and shared vertices for axis-aligned rectangles and glyph quads.
* **Optional LZ4 / Heatshrink Compression:** Wrapping `MSG_DRAW_CHUNK` payloads in a fast, low-memory compressor like **Heatshrink** (configurable down to a 256-byte sliding window) typically compresses repetitive UI vertex data by 2x–3x.

---

## 9. Implementation Roadmap

### Phase 1: Wire Protocol and Serial Loopback
* Implement the COBS encoder/decoder and `CRC16` module in portable C.
* Build a host-side serial loopback test tool on macOS/Windows/Linux to verify zero packet loss at 1 Mbps sustained throughput.

### Phase 2: Single-Core Nuklear Draw Serialization
* Integrate `nuklear.h` on a single embedded core using static memory buffers (`nk_init_fixed`).
* Write a custom draw-list serializer that converts `nk_convert()` output into `MSG_DRAW_BEGIN`, `MSG_DRAW_CHUNK`, and `MSG_DRAW_END` packets.
* Build the minimal SDL2 host renderer to open one window and render the incoming Nuklear draw lists.

### Phase 3: Upstream Input and Focus Synchronization
* Add SDL2 keyboard and mouse event capture on the host and transmit `MSG_INPUT_KEY` and `MSG_INPUT_MOUSE` packets to the target.
* Feed incoming packets into `nk_input_begin()` / `nk_input_end()` on the embedded core to verify interactive buttons, sliders, and text fields.

### Phase 4: Multi-Core Internal Mux/Demux Adapter
* Implement per-core TX/RX ring buffers and packet-atomic round-robin TX arbitration in the internal adapter.
* Implement `active_focus_core_id` routing and bidirectional `MSG_FOCUS_EVENT` synchronization between the internal hardware focus selector and the desktop host's multi-window manager.

### Phase 5: Bandwidth Tuning and Resilience
* Switch vertex coordinates to fixed-point `int16_t` and add `MSG_REFRESH_ALL` reconnection recovery.
* Add per-core credit flow control so background cores never stall interactive input latency on the focused core.
