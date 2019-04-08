vcl 4.0;

backend default {
    .host = "FRONTEND_SERVICE_HOST";
    .port = "FRONTEND_SERVICE_PORT";
}

sub vcl_recv {

    if (req.restarts == 0) {

        if (req.http.x-forwarded-for) {

            set req.http.X-Forwarded-For = req.http.X-Forwarded-For + ", " + client.ip;

        } else {

            set req.http.X-Forwarded-For = client.ip;

        }

    }
    
    if (req.http.host ~ "[ONE_DOMAIN]" && !req.url  ~ "^/hi/|^/hi") {
       
       set req.backend_hint = [ONE_BACKEND];
       
    } elseif (req.http.host ~ "[ANOTHER_DOMAIN]" && req.url  ~ "^/hi/|^/hi") {
      
      set req.backend_hint = [ANOTHER_BACKEND]; 
      
    } else {
      
      set req.backend_hint = default;
      
    }

    # Only cache GET or HEAD requests. This makes sure the POST requests are always passed.
    if (req.method != "GET" && req.method != "HEAD" && req.method != "PURGE") {

        return (pass);

    }

    if (req.url ~ "^\/xmlrpc.php") {

        return (synth(405, "Not allowed"));

    }

    # Strip hash, server doesn't need it.
    if (req.url ~ "\#") {

        set req.url = regsub(req.url, "\#.*$", "");

    }

    # Strip a trailing ? if it exists
    if (req.url ~ "\?$") {

        set req.url = regsub(req.url, "\?$", "");

    }

    # Purge 
    if (req.method == "PURGE") {

        if (req.url ~ "purge_all") {

            ban("req.http.host ~ .*");

            return(purge);

        }else{

            ban("req.url == " + req.url);

            return(purge);

        }

    }

    if (req.url !~ "(wp-json*|customize_changeset_uuid|preview_id|wp-admin/admin-ajax.php|\?wc-ajax=checkout|finalizar*|wp-admin*|myaccess|wp-login.php|wc-api/v3/*|area-de-usuario/*|adminer*|finalizar-compra*|carro*|mi-cuenta*)") {

        unset req.http.cookie;

    }

    # Large static files are delivered directly to the end-user without
    # waiting for Varnish to fully read the file first.
    # Varnish 4 fully supports Streaming, so set do_stream in vcl_backend_response()
    if (req.url ~ "^[^?]*\.(7z|avi|bz2|flac|flv|gz|mka|mkv|mov|mp3|mp4|mpeg|mpg|ogg|ogm|opus|rar|tar|tgz|tbz|txz|wav|webm|xz|zip)(\?.*)?$") {

        unset req.http.Cookie;

        return (hash);

    }

    # Remove all cookies for static files
    # A valid discussion could be held on this line: do you really need to cache static files that don't cause load? Only if you have memory left.
    # Sure, there's disk I/O, but chances are your OS will already have these files in their buffers (thus memory).
    # Before you blindly enable this, have a read here: https://ma.ttias.be/stop-caching-static-files/
    if (req.url ~ "^[^?]*\.(7z|avi|bmp|bz2|css|csv|doc|docx|eot|flac|flv|gif|gz|ico|jpeg|jpg|js|less|mka|mkv|mov|mp3|mp4|mpeg|mpg|odt|otf|ogg|ogm|opus|pdf|png|ppt|pptx|rar|rtf|svg|svgz|swf|tar|tbz|tgz|ttf|txt|txz|wav|webm|webp|woff|woff2|xls|xlsx|xml|xz|zip)(\?.*)?$") {

        unset req.http.Cookie;

        return (hash);

    }

    # Send Surrogate-Capability headers to announce ESI support to backend
    set req.http.Surrogate-Capability = "key=ESI/1.0";

    if (req.http.Authorization) {

        # Not cacheable by default
        return (pass);

    }

    return(hash);

}

sub vcl_miss {

    # Called after a cache lookup if the requested document was not found in the cache. Its purpose
    # is to decide whether or not to attempt to retrieve the document from the backend, and which
    # backend to use.

    return (fetch);

}

sub vcl_backend_response {

    # Force to cache by cache-control header
    unset beresp.http.etag;

    # Remove Vary header response. Only if theme is browser-agnostic or responsive.
    unset beresp.http.Vary;

    if (! bereq.url ~ "(wp-json*|customize_changeset_uuid|preview_id|wp-admin/admin-ajax.php|\?wc-ajax=checkout|finalizar*|wp-admin*|myaccess|wp-login.php|wc-api/v3/*|area-de-usuario/*|adminer*|finalizar-compra|carro*|mi-cuenta*)") {

        unset beresp.http.cookie;
        unset beresp.http.Set-Cookie;
        unset beresp.http.Cache-Control;
        set beresp.ttl = 1h;

        # 7-9-2018 David Barreiros. He metido esta línea dentro del condicional porque provocaba un HIT en las páginas del wp-admin.
        # Set 2min cache if unset for static files
        if (beresp.ttl <= 0s || beresp.http.Set-Cookie || beresp.http.Vary == "*") {

            set beresp.ttl = 120s; # Important, you shouldn't rely on this, SET YOUR HEADERS in the backend

        }

    }

    # Don't cache 50x responses
    if (beresp.status == 500 || beresp.status == 502 || beresp.status == 503 || beresp.status == 504) {

        return (abandon);

    }

    return (deliver);

}

# The data on which the hashing will take place
sub vcl_hash {

    # Called after vcl_recv to create a hash value for the request. This is used as a key
    # to look up the object in Varnish.

    hash_data(req.url);

    if (req.http.host) {

        hash_data(req.http.host);

    } else {

        hash_data(server.ip);

    }

    # hash cookies for requests that have them
    if (req.http.Cookie) {

        hash_data(req.http.Cookie);

    }

}

sub vcl_deliver {

    if (obj.hits > 0) {

        set resp.http.X-Cache = "HIT";

    } else {

        set resp.http.X-Cache = "MISS";

    }

    # Please note that obj.hits behaviour changed in 4.0, now it counts per objecthead, not per object
    # and obj.hits may not be reset in some cases where bans are in use. See bug 1492 for details.
    # So take hits with a grain of salt
    set resp.http.X-Cache-Hits = obj.hits;

    # Remove some headers: PHP version
    unset resp.http.X-Powered-By;

    # Remove some headers: Apache version & OS
    unset resp.http.Server;
    unset resp.http.X-Drupal-Cache;
    unset resp.http.X-Varnish;
    unset resp.http.Via;
    unset resp.http.Link;
    unset resp.http.X-Generator;
    unset resp.http.Vary;

    return (deliver);

}

