from fastapi import Request


def get_ipaddr(request: Request) -> str:
    """Returns the IP address for the current request through the `X-Forwarded-For` headers

    Args:
        request (Request): Instance of `Request`

    Returns:
        str: IP Address from the request
    """
    if "X_FORWARDED_FOR" in request.headers:
        return request.headers["X_FORWARDED_FOR"]
    else:
        if not request.client or not request.client.host:
            return "127.0.0.1"

        return request.client.host


def get_remote_address(request: Request) -> str:
    """Returns the IP address through the currently provided request

    Args:
        request: (Request): Instance of `Request`

    Returns:
        str: IP Address from the request
    """
    if not request.client or not request.client.host:
        return "127.0.0.1"

    return request.client.host
