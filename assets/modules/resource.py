"""
Inspect resources configured for dispatch on this minion.

Minion-side counterpart to the ``resource`` runner: Salt's resource
dispatch (``salt-call -r`` with ``--tgt``/``--tgt-type``) reads resource
declarations from pillar, but does not currently expose a way to inspect
them on the minion. Where the runner reads the master's
``resource_grains`` cache bank, this module renders resource grains
live via each type's connection module — there is no master-side cache
in masterless operation.

Candidate for upstreaming into Salt proper.
"""

import logging

import salt.loader
import salt.loader.context
import salt.utils.resources

log = logging.getLogger(__name__)

__virtualname__ = "resource"
__func_alias__ = {"list_": "list"}


def __virtual__():
    return __virtualname__


def list_(type=None):  # noqa: A002 — keep CLI-friendly param names
    """
    List resources configured for dispatch, grouped by resource type.

    type
        Only return resource IDs of this type.

    CLI Example:

    .. code-block:: bash

        salt-call resource.list
        salt-call resource.list type=github
    """
    # Prefer the post-discovery mapping ({type: [id, ...]}) when the minion
    # has populated it, falling back to the raw pillar declaration
    # ({type: {"resource_ids": [...]}}).
    tree = __opts__.get("resources")
    if not isinstance(tree, dict) or not tree:
        key = salt.utils.resources.resource_pillar_key(__opts__)
        tree = __pillar__.get(key) or {}

    out = {}
    for rtype, decl in tree.items():
        if isinstance(decl, list):
            ids = decl
        elif isinstance(decl, dict):
            ids = decl.get("resource_ids") or []
        else:
            ids = []
        out[rtype] = sorted(str(rid) for rid in ids)

    if type is not None:
        return out.get(type, [])
    return out


def types():
    """
    List resource types that have at least one configured resource.

    CLI Example:

    .. code-block:: bash

        salt-call resource.types
    """
    return sorted(rtype for rtype, ids in list_().items() if ids)


def _resource_funcs():
    """
    Build the resource connection loader the same way the minion does
    (:func:`salt.loader.resource` + per-type ``init()``).
    """
    utils = salt.loader.utils(__opts__)
    rfuncs = salt.loader.resource(
        __opts__, functions=__salt__, utils=utils, context=__context__
    )
    for rtype in types():
        init_fn = f"{rtype}.init"
        if init_fn in rfuncs:
            try:
                rfuncs[init_fn](__opts__)
            except Exception as exc:  # pylint: disable=broad-except
                log.error("Failed to initialize resource type '%s': %s", rtype, exc)
    return rfuncs


def _render_grains(rfuncs, rtype, rid):
    """
    Render one resource's grain dict under the per-call resource context,
    mirroring ``Minion._collect_resource_grains``. Returns None for types
    without a ``grains`` callable or on per-resource failure.
    """
    grains_fn = f"{rtype}.grains"
    if grains_fn not in rfuncs:
        return None
    tok = salt.loader.context.resource_ctxvar.set({"id": rid, "type": rtype})
    try:
        gdict = rfuncs[grains_fn]()
    except Exception as exc:  # pylint: disable=broad-except
        log.warning("Failed to collect grains for resource %s:%s: %s", rtype, rid, exc)
        return None
    finally:
        salt.loader.context.resource_ctxvar.reset(tok)
    return gdict if isinstance(gdict, dict) else None


def show_grains(type, id):  # noqa: A002 — keep CLI-friendly param names
    """
    Return the grain dict for one configured resource, or ``None`` if the
    resource is not configured or its type provides no grains.

    Unlike the ``resource.show_grains`` runner (which reads the master's
    cache bank), the grains are rendered live by the resource type's
    connection module.

    type
        The resource type (e.g. ``github``).

    id
        The bare resource id (e.g. ``myorg/myrepo``).

    CLI Example:

    .. code-block:: bash

        salt-call resource.show_grains type=github id=myorg/myrepo
    """
    if not type or not id:
        return None
    if str(id) not in list_(type=type):
        return None
    return _render_grains(_resource_funcs(), type, id)


def list_grains():
    """
    Return every configured resource's SRN (``<type>:<id>``) along with a
    short grains summary (top-level grain keys, count), mirroring the
    ``resource.list_grains`` runner's output shape. Grains are rendered
    live; resources whose type provides no grains are skipped.

    CLI Example:

    .. code-block:: bash

        salt-call resource.list_grains
    """
    rfuncs = _resource_funcs()
    summary = {}
    for rtype, rids in list_().items():
        for rid in rids:
            gdict = _render_grains(rfuncs, rtype, rid)
            if gdict is None:
                continue
            summary[f"{rtype}:{rid}"] = {
                "grain_keys": sorted(gdict.keys()),
                "grain_count": len(gdict),
            }
    return summary
