# tb/cocotb/common/axi_driver.py

from cocotb.triggers import RisingEdge


class AXILiteTimeoutError(TimeoutError):
    pass


class AXILiteMaster:
    """
    Simple AXI4-Lite master driver for cocotb tests.

    Features:
      - Drives all AXI-Lite master-side inputs to known idle values.
      - Supports independent AW/W handshakes to avoid write-channel deadlock.
      - Checks BRESP/RRESP == OKAY.
      - Adds timeout to every transaction.
      - Cleans up VALID/READY signals on failure.
    """

    AXI_RESP_OKAY = 0

    def __init__(self, dut, clk, rst_n=None, timeout_cycles=1000):
        self.dut = dut
        self.clk = clk
        self.rst_n = rst_n
        self.timeout_cycles = timeout_cycles

        self.drive_idle()

    # ------------------------------------------------------------------
    # Public APIs
    # ------------------------------------------------------------------

    def drive_idle(self):
        """
        Drive AXI-Lite master-side signals to known idle values.

        Important:
            Instantiate this driver before reset is released so that DUT
            inputs are not left as X during reset.
        """
        self.dut.s_axil_awaddr.value = 0
        self.dut.s_axil_awvalid.value = 0

        self.dut.s_axil_wdata.value = 0
        self.dut.s_axil_wstrb.value = 0
        self.dut.s_axil_wvalid.value = 0

        self.dut.s_axil_bready.value = 0

        self.dut.s_axil_araddr.value = 0
        self.dut.s_axil_arvalid.value = 0

        self.dut.s_axil_rready.value = 0

    async def wait_reset_released(self, extra_cycles=1):
        """
        Optional helper. Wait until rst_n is high, then wait extra cycles.

        Use only if rst_n was passed to the constructor.
        """
        if self.rst_n is None:
            return

        while not self._is_one(self.rst_n):
            await RisingEdge(self.clk)

        for _ in range(extra_cycles):
            await RisingEdge(self.clk)

    async def write(self, addr, data, wstrb=0xF, timeout_cycles=None):
        """
        Perform one AXI4-Lite write transaction.

        AXI-Lite write has independent AW and W channels. This driver
        asserts AWVALID and WVALID together, but accepts that AWREADY and
        WREADY may arrive in different cycles.

        Args:
            addr: 32-bit register address.
            data: 32-bit write data.
            wstrb: 4-bit byte strobe. Default 0xF for full 32-bit write.
            timeout_cycles: optional override for this transaction.

        Returns:
            bresp value.
        """
        timeout = timeout_cycles or self.timeout_cycles

        aw_done = False
        w_done = False
        bresp = None

        try:
            # Drive AW channel.
            self.dut.s_axil_awaddr.value = int(addr) & 0xFFFFFFFF
            self.dut.s_axil_awvalid.value = 1

            # Drive W channel.
            self.dut.s_axil_wdata.value = int(data) & 0xFFFFFFFF
            self.dut.s_axil_wstrb.value = int(wstrb) & 0xF
            self.dut.s_axil_wvalid.value = 1

            # Wait for both AW and W handshakes independently.
            for cycle in range(timeout):
                await RisingEdge(self.clk)

                if (not aw_done) and self._is_one(self.dut.s_axil_awready):
                    aw_done = True
                    self.dut.s_axil_awvalid.value = 0

                if (not w_done) and self._is_one(self.dut.s_axil_wready):
                    w_done = True
                    self.dut.s_axil_wvalid.value = 0

                if aw_done and w_done:
                    break
            else:
                raise AXILiteTimeoutError(
                    f"AXI-Lite write address/data handshake timeout: "
                    f"addr=0x{int(addr):08X}, data=0x{int(data) & 0xFFFFFFFF:08X}, "
                    f"aw_done={aw_done}, w_done={w_done}"
                )

            # Make sure VALID signals are deasserted after handshakes.
            self.dut.s_axil_awvalid.value = 0
            self.dut.s_axil_wvalid.value = 0

            # Wait for write response.
            self.dut.s_axil_bready.value = 1

            for cycle in range(timeout):
                await RisingEdge(self.clk)

                if self._is_one(self.dut.s_axil_bvalid):
                    bresp = self._get_int(self.dut.s_axil_bresp, "s_axil_bresp")
                    if bresp != self.AXI_RESP_OKAY:
                        raise AssertionError(
                            f"AXI-Lite write BRESP error: "
                            f"addr=0x{int(addr):08X}, "
                            f"data=0x{int(data) & 0xFFFFFFFF:08X}, "
                            f"bresp={bresp}"
                        )
                    break
            else:
                raise AXILiteTimeoutError(
                    f"AXI-Lite write response timeout: "
                    f"addr=0x{int(addr):08X}, data=0x{int(data) & 0xFFFFFFFF:08X}"
                )

            return bresp

        finally:
            # Cleanup even if timeout/assertion happens.
            self.dut.s_axil_awvalid.value = 0
            self.dut.s_axil_wvalid.value = 0
            self.dut.s_axil_bready.value = 0

    async def read(self, addr, timeout_cycles=None):
        """
        Perform one AXI4-Lite read transaction.

        Args:
            addr: 32-bit register address.
            timeout_cycles: optional override for this transaction.

        Returns:
            32-bit read data as int.
        """
        timeout = timeout_cycles or self.timeout_cycles

        ar_done = False
        data = None

        try:
            # Drive AR channel.
            self.dut.s_axil_araddr.value = int(addr) & 0xFFFFFFFF
            self.dut.s_axil_arvalid.value = 1

            # Ready to accept R data immediately.
            # This supports slaves that return RVALID as soon as AR handshakes.
            self.dut.s_axil_rready.value = 1

            for cycle in range(timeout):
                await RisingEdge(self.clk)

                if (not ar_done) and self._is_one(self.dut.s_axil_arready):
                    ar_done = True
                    self.dut.s_axil_arvalid.value = 0

                if self._is_one(self.dut.s_axil_rvalid):
                    if not ar_done:
                        raise AssertionError(
                            f"AXI-Lite RVALID arrived before AR handshake: "
                            f"addr=0x{int(addr):08X}"
                        )

                    rresp = self._get_int(self.dut.s_axil_rresp, "s_axil_rresp")
                    if rresp != self.AXI_RESP_OKAY:
                        raise AssertionError(
                            f"AXI-Lite read RRESP error: "
                            f"addr=0x{int(addr):08X}, rresp={rresp}"
                        )

                    data = self._get_int(self.dut.s_axil_rdata, "s_axil_rdata")
                    break
            else:
                raise AXILiteTimeoutError(
                    f"AXI-Lite read timeout: addr=0x{int(addr):08X}, ar_done={ar_done}"
                )

            return data & 0xFFFFFFFF

        finally:
            # Cleanup even if timeout/assertion happens.
            self.dut.s_axil_arvalid.value = 0
            self.dut.s_axil_rready.value = 0

    async def write_many(self, items, timeout_cycles=None):
        """
        Convenience helper for multiple writes.

        Args:
            items: iterable of (addr, data) or (addr, data, wstrb)
        """
        for item in items:
            if len(item) == 2:
                addr, data = item
                await self.write(addr, data, timeout_cycles=timeout_cycles)
            elif len(item) == 3:
                addr, data, wstrb = item
                await self.write(addr, data, wstrb=wstrb, timeout_cycles=timeout_cycles)
            else:
                raise ValueError(f"Invalid write_many item: {item}")

    async def read_many(self, addrs, timeout_cycles=None):
        """
        Convenience helper for multiple reads.

        Returns:
            dict: {addr: data}
        """
        result = {}
        for addr in addrs:
            result[addr] = await self.read(addr, timeout_cycles=timeout_cycles)
        return result

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _is_one(self, sig):
        """
        Safe check for signal == 1.

        Returns False for X/Z/unresolvable values instead of accidentally
        treating them as true.
        """
        try:
            val = sig.value
            if hasattr(val, "is_resolvable") and not val.is_resolvable:
                return False
            return int(val) == 1
        except Exception:
            return False

    def _get_int(self, sig, name="signal"):
        """
        Convert signal value to int and fail loudly on X/Z.
        """
        val = sig.value

        if hasattr(val, "is_resolvable") and not val.is_resolvable:
            raise AssertionError(f"{name} has X/Z value: {val}")

        try:
            return int(val)
        except Exception as exc:
            raise AssertionError(f"Cannot convert {name}={val} to int") from exc
