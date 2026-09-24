require "erb"

module Kulla
  # View helper. Put <%= kulla_beacon_tag %> in the layout (head or body; it runs once per page load
  # and follows Turbo navigations). No cookies; the visitor id is computed server-side.
  module Helper
    BEACON_JS = <<~JS.gsub(/^\s+/, "").tr("\n", "").freeze
      (function(){
      if(window.__kulla)return;window.__kulla=1;
      var url=__URL__,s,sent,prev=location.href;
      function reset(ref,soft){s={path:location.pathname,referrer:ref,cls:0,soft:soft};sent=false;}
      reset(document.referrer,false);
      function device(){var w=Math.min(screen.width,screen.height);return w<600?"phone":(w<1024&&navigator.maxTouchPoints>0)?"tablet":"desktop";}
      function observe(type,cb,opts){try{var o={type:type,buffered:true};for(var k in opts)o[k]=opts[k];new PerformanceObserver(function(l){l.getEntries().forEach(cb);}).observe(o);}catch(e){}}
      observe("largest-contentful-paint",function(e){if(!s.soft)s.lcp_ms=Math.round(e.startTime);});
      observe("layout-shift",function(e){if(!e.hadRecentInput)s.cls+=e.value;});
      observe("event",function(e){if(e.interactionId)s.inp_ms=Math.max(s.inp_ms||0,Math.round(e.duration));},{durationThreshold:40});
      function send(){if(sent)return;sent=true;
      var body=JSON.stringify({path:s.path,referrer:s.referrer,viewport:innerWidth+"x"+innerHeight,device:device(),lcp_ms:s.lcp_ms,inp_ms:s.inp_ms,cls:Math.round(s.cls*10000)/10000});
      try{if(navigator.sendBeacon&&navigator.sendBeacon(url,new Blob([body],{type:"text/plain"})))return;
      fetch(url,{method:"POST",body:body,keepalive:true,credentials:"same-origin"});}catch(e){}}
      addEventListener("visibilitychange",function(){if(document.visibilityState==="hidden")send();});
      addEventListener("pagehide",send);
      document.addEventListener("turbo:visit",send);
      document.addEventListener("turbo:load",function(){if(sent)reset(prev,true);prev=location.href;});
      })();
    JS

    def kulla_beacon_tag(path: VisitEndpoint::PATH)
      config = Kulla.config
      return unless config.enabled? && config.capture?(:visits)

      nonce = content_security_policy_nonce if respond_to?(:content_security_policy_nonce)
      nonce_attr = nonce ? %( nonce="#{ERB::Util.html_escape(nonce)}") : ""
      html = %(<script#{nonce_attr}>#{Helper.beacon_js(path)}</script>)
      html.respond_to?(:html_safe) ? html.html_safe : html
    rescue StandardError => e
      Kulla.log("kulla_beacon_tag failed: #{e.class}: #{e.message}")
      nil
    end

    def self.beacon_js(path = VisitEndpoint::PATH)
      BEACON_JS.sub("__URL__") { JSON.generate(path.to_s).gsub("</", "<\\/") }
    end
  end
end
