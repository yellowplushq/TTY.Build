// Permanent redirect from the retired service hostname to https://tty.build.
// Path and query are preserved so old links keep resolving.
export default {
  fetch(request) {
    const url = new URL(request.url);
    return Response.redirect(`https://tty.build${url.pathname}${url.search}`, 301);
  },
};
