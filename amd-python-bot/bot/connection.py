"""
MT5 connection — AMD bot.

Credential priority:
  1. keyring.get_password('mt5', '<profile>_password')  — Windows Credential Manager
  2. MT5_PASSWORD in .env                               — fallback only

Store password once:
  python -c "import keyring; keyring.set_password('mt5', 'metaquotes_password', 'YOUR_PW')"
"""

import os
import MetaTrader5 as mt5

try:
    import keyring as _keyring
except ImportError:
    _keyring = None  # type: ignore


def _get_password(profile: str) -> str | None:
    if _keyring is not None:
        pw = _keyring.get_password("mt5", f"{profile}_password")
        if pw:
            return pw
    return os.getenv("MT5_PASSWORD")


def connect(profile: str = "default") -> None:
    login    = os.getenv("MT5_LOGIN")
    password = _get_password(profile)
    server   = os.getenv("MT5_SERVER")
    path     = os.getenv("MT5_PATH")

    kwargs: dict = {}
    if path:
        kwargs["path"] = path
    if login and password and server:
        kwargs.update(login=int(login), password=password, server=server)

    ok = mt5.initialize(**kwargs) if kwargs else mt5.initialize()

    if not ok:
        raise RuntimeError(f"MT5 connection failed: {mt5.last_error()}")

    info = mt5.account_info()
    if info is None:
        raise RuntimeError(f"Could not retrieve account info: {mt5.last_error()}")

    print("\n  Connected to MetaTrader 5")
    print(f"  Account  : {info.name}  (#{info.login})")
    print(f"  Server   : {info.server}")
    print(f"  Balance  : {info.balance:,.2f} {info.currency}")
    print(f"  Leverage : 1:{info.leverage}")


def disconnect() -> None:
    mt5.shutdown()
    print("\n  Disconnected from MT5.")
