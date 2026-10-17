"""
Returner backing ``SALT_RESULT_FILE``: dump the job return as JSON to
the path configured as ``push_result.file``.

The Salt process writes the JSON itself, so consumers (e.g. the GitHub
Action) read it without Salt libraries — no msgpack job cache
post-processing.

Two shapes, selected via config (push-entrypoint.sh sets the keys):

- salt-call/salt (``--return push_result``): the single job return,
  dumped as-is.
- salt-ssh (``master_job_cache: push_result`` +
  ``push_result.accumulate: True``): per-target returns accumulated into
  ``{jid, returns: {target: return}}``. The master_job_cache interface
  stubs persist nothing else, so no msgpack job cache is written.
"""

import json
import os

import salt.utils.jid

__virtualname__ = "push_result"


def __virtual__():
    if not __opts__.get("push_result.file"):
        return False, "push_result.file is not configured"
    return __virtualname__


def _write(data):
    path = __opts__["push_result.file"]
    tmp = f"{path}.tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, default=str)
    os.replace(tmp, path)


def returner(ret):
    """
    Write the job return. With ``push_result.accumulate``, fold
    per-target returns (one call each, salt-ssh master_job_cache style)
    into a single document.
    """
    if not __opts__.get("push_result.accumulate"):
        _write(ret)
        return
    data = {"jid": ret.get("jid"), "returns": {}}
    try:
        with open(__opts__["push_result.file"], encoding="utf-8") as fh:
            prev = json.load(fh)
        if isinstance(prev, dict) and prev.get("jid") == ret.get("jid"):
            data = prev
    except (OSError, ValueError):
        pass
    data["returns"][ret["id"]] = ret.get("return")
    _write(data)


def prep_jid(nocache=False, passed_jid=None):
    """
    master_job_cache interface: no jid directory to prepare.
    """
    return passed_jid or salt.utils.jid.gen_jid(__opts__)


def save_load(jid, clear_load, minions=None):
    """
    master_job_cache interface: the invocation load is not persisted.
    """


def get_load(jid):
    """
    master_job_cache interface: nothing is persisted to read back.
    """
    return {}
