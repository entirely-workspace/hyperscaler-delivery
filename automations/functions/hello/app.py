"""An example function: the example workflow calls it with {"name": ...} and gets a greeting back."""


def handler(event, _context):
    name = (event or {}).get("name") or "world"
    return {"greeting": f"Hello, {name}"}
