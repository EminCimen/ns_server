import{b as s}from"./common/tslib.es6-c4a4947b.js";import{O as l,d as h,e as p,h as y,r as j,p as I,i as F,g as M,S as P,t as _}from"./common/mergeMap-64c6f393.js";export{k as ObjectUnsubscribedError,O as Observable,a as Subject,b as Subscriber,S as Subscription,U as UnsubscriptionError,x as config,g as from,i as identity,o as noop,u as observable,v as pipe,w as scheduled}from"./common/mergeMap-64c6f393.js";export{C as ConnectableObservable,m as merge}from"./common/merge-183efbc7.js";import{A as J,d as V,n as Y}from"./common/zip-41358de8.js";export{A as AsyncSubject,G as GroupedObservable,T as TimeoutError,a as asapScheduler,d as defer,z as zip}from"./common/zip-41358de8.js";export{B as BehaviorSubject,c as combineLatest,a as concat}from"./common/concat-981db672.js";import{a as K,A as L,E as D}from"./common/Notification-9e07e457.js";export{E as EMPTY,N as Notification,b as NotificationKind,S as Scheduler,e as empty,t as throwError}from"./common/Notification-9e07e457.js";export{R as ReplaySubject,q as queueScheduler}from"./common/ReplaySubject-8316d9c1.js";import{f as H}from"./common/filter-d76a729c.js";export{o as of}from"./common/filter-d76a729c.js";import{i as Q,a as W}from"./common/timer-a781bf0e.js";export{a as asyncScheduler,r as race,t as timer}from"./common/timer-a781bf0e.js";export{A as ArgumentOutOfRangeError}from"./common/ArgumentOutOfRangeError-91c779f5.js";export{E as EmptyError}from"./common/EmptyError-a9e17542.js";export{f as forkJoin}from"./common/forkJoin-269e2e92.js";export{N as NEVER,f as fromEvent,n as never}from"./common/never-2f7c2de7.js";var X=function(e){function r(r,t){var n=e.call(this,r,t)||this;return n.scheduler=r,n.work=t,n}return s(r,e),r.prototype.requestAsyncId=function(r,t,n){return void 0===n&&(n=0),null!==n&&n>0?e.prototype.requestAsyncId.call(this,r,t,n):(r.actions.push(this),r.scheduled||(r.scheduled=requestAnimationFrame((function(){return r.flush(null)}))))},r.prototype.recycleAsyncId=function(r,t,n){if(void 0===n&&(n=0),null!==n&&n>0||null===n&&this.delay>0)return e.prototype.recycleAsyncId.call(this,r,t,n);0===r.actions.length&&(cancelAnimationFrame(t),r.scheduled=void 0)},r}(K),Z=new(function(e){function r(){return null!==e&&e.apply(this,arguments)||this}return s(r,e),r.prototype.flush=function(e){this.active=!0,this.scheduled=void 0;var r,t=this.actions,n=-1,o=t.length;e=e||t.shift();do{if(r=e.execute(e.state,e.delay))break}while(++n<o&&(e=t.shift()));if(this.active=!1,r){for(;++n<o&&(e=t.shift());)e.unsubscribe();throw r}},r}(L))(X),$=function(e){function r(r,t){void 0===r&&(r=ee),void 0===t&&(t=Number.POSITIVE_INFINITY);var n=e.call(this,r,(function(){return n.frame}))||this;return n.maxFrames=t,n.frame=0,n.index=-1,n}return s(r,e),r.prototype.flush=function(){for(var e,r,t=this.actions,n=this.maxFrames;(r=t[0])&&r.delay<=n&&(t.shift(),this.frame=r.delay,!(e=r.execute(r.state,r.delay))););if(e){for(;r=t.shift();)r.unsubscribe();throw e}},r.frameTimeFactor=10,r}(L),ee=function(e){function r(r,t,n){void 0===n&&(n=r.index+=1);var o=e.call(this,r,t)||this;return o.scheduler=r,o.work=t,o.index=n,o.active=!0,o.index=r.index=n,o}return s(r,e),r.prototype.schedule=function(t,n){if(void 0===n&&(n=0),!this.id)return e.prototype.schedule.call(this,t,n);this.active=!1;var o=new r(this.scheduler,this.work);return this.add(o),o.schedule(t,n)},r.prototype.requestAsyncId=function(e,t,n){void 0===n&&(n=0),this.delay=e.frame+n;var o=e.actions;return o.push(this),o.sort(r.sortActions),!0},r.prototype.recycleAsyncId=function(e,r,t){},r.prototype._execute=function(r,t){if(!0===this.active)return e.prototype._execute.call(this,r,t)},r.sortActions=function(e,r){return e.delay===r.delay?e.index===r.index?0:e.index>r.index?1:-1:e.delay>r.delay?1:-1},r}(K);function re(e){return!!e&&(e instanceof l||"function"==typeof e.lift&&"function"==typeof e.subscribe)}function te(e,r,t){if(r){if(!h(r))return function(){for(var n=[],o=0;o<arguments.length;o++)n[o]=arguments[o];return te(e,t).apply(void 0,n).pipe(p((function(e){return y(e)?r.apply(void 0,e):r(e)})))};t=r}return function(){for(var r=[],n=0;n<arguments.length;n++)r[n]=arguments[n];var o,c=this,i={context:c,subject:o,callbackFunc:e,scheduler:t};return new l((function(n){if(t){var s={args:r,subscriber:n,params:i};return t.schedule(ne,0,s)}if(!o){o=new J;try{e.apply(c,r.concat([function(){for(var e=[],r=0;r<arguments.length;r++)e[r]=arguments[r];o.next(e.length<=1?e[0]:e),o.complete()}]))}catch(e){j(o)?o.error(e):console.warn(e)}}return o.subscribe(n)}))}}function ne(e){var r=this,t=e.args,n=e.subscriber,o=e.params,c=o.callbackFunc,i=o.context,s=o.scheduler,a=o.subject;if(!a){a=o.subject=new J;try{c.apply(i,t.concat([function(){for(var e=[],t=0;t<arguments.length;t++)e[t]=arguments[t];var n=e.length<=1?e[0]:e;r.add(s.schedule(oe,0,{value:n,subject:a}))}]))}catch(e){a.error(e)}}this.add(a.subscribe(n))}function oe(e){var r=e.value,t=e.subject;t.next(r),t.complete()}function ce(e,r,t){if(r){if(!h(r))return function(){for(var n=[],o=0;o<arguments.length;o++)n[o]=arguments[o];return ce(e,t).apply(void 0,n).pipe(p((function(e){return y(e)?r.apply(void 0,e):r(e)})))};t=r}return function(){for(var r=[],n=0;n<arguments.length;n++)r[n]=arguments[n];var o={subject:void 0,args:r,callbackFunc:e,scheduler:t,context:this};return new l((function(n){var c=o.context,i=o.subject;if(t)return t.schedule(ie,0,{params:o,subscriber:n,context:c});if(!i){i=o.subject=new J;try{e.apply(c,r.concat([function(){for(var e=[],r=0;r<arguments.length;r++)e[r]=arguments[r];var t=e.shift();t?i.error(t):(i.next(e.length<=1?e[0]:e),i.complete())}]))}catch(e){j(i)?i.error(e):console.warn(e)}}return i.subscribe(n)}))}}function ie(e){var r=this,t=e.params,n=e.subscriber,o=e.context,c=t.callbackFunc,i=t.args,s=t.scheduler,a=t.subject;if(!a){a=t.subject=new J;try{c.apply(o,i.concat([function(){for(var e=[],t=0;t<arguments.length;t++)e[t]=arguments[t];var n=e.shift();if(n)r.add(s.schedule(ae,0,{err:n,subject:a}));else{var o=e.length<=1?e[0]:e;r.add(s.schedule(se,0,{value:o,subject:a}))}}]))}catch(e){this.add(s.schedule(ae,0,{err:e,subject:a}))}}this.add(a.subscribe(n))}function se(e){var r=e.value,t=e.subject;t.next(r),t.complete()}function ae(e){var r=e.err;e.subject.error(r)}function ue(e,r,t){return t?ue(e,r).pipe(p((function(e){return y(e)?t.apply(void 0,e):t(e)}))):new l((function(t){var n,o=function(){for(var e=[],r=0;r<arguments.length;r++)e[r]=arguments[r];return t.next(1===e.length?e[0]:e)};try{n=e(o)}catch(e){return void t.error(e)}if(I(r))return function(){return r(o,n)}}))}function fe(e,r,t,n,o){var c,i;if(1==arguments.length){var s=e;i=s.initialState,r=s.condition,t=s.iterate,c=s.resultSelector||F,o=s.scheduler}else void 0===n||h(n)?(i=e,c=F,o=n):(i=e,c=n);return new l((function(e){var n=i;if(o)return o.schedule(le,0,{subscriber:e,iterate:t,condition:r,resultSelector:c,state:n});for(;;){if(r){var s=void 0;try{s=r(n)}catch(r){return void e.error(r)}if(!s){e.complete();break}}var a=void 0;try{a=c(n)}catch(r){return void e.error(r)}if(e.next(a),e.closed)break;try{n=t(n)}catch(r){return void e.error(r)}}}))}function le(e){var r=e.subscriber,t=e.condition;if(!r.closed){if(e.needIterate)try{e.state=e.iterate(e.state)}catch(e){return void r.error(e)}else e.needIterate=!0;if(t){var n=void 0;try{n=t(e.state)}catch(e){return void r.error(e)}if(!n)return void r.complete();if(r.closed)return}var o;try{o=e.resultSelector(e.state)}catch(e){return void r.error(e)}if(!r.closed&&(r.next(o),!r.closed))return this.schedule(e)}}function de(e,r,t){return void 0===r&&(r=D),void 0===t&&(t=D),V((function(){return e()?r:t}))}function he(e,r){return void 0===e&&(e=0),void 0===r&&(r=W),(!Q(e)||e<0)&&(e=0),r&&"function"==typeof r.schedule||(r=W),new l((function(t){return t.add(r.schedule(pe,e,{subscriber:t,counter:0,period:e})),t}))}function pe(e){var r=e.subscriber,t=e.counter,n=e.period;r.next(t),this.schedule({subscriber:r,counter:t+1,period:n},n)}function be(){for(var e=[],r=0;r<arguments.length;r++)e[r]=arguments[r];if(0===e.length)return D;var t=e[0],n=e.slice(1);return 1===e.length&&y(t)?be.apply(void 0,t):new l((function(e){var r=function(){return e.add(be.apply(void 0,n).subscribe(e))};return M(t).subscribe({next:function(r){e.next(r)},error:r,complete:r})}))}function me(e,r){return new l(r?function(t){var n=Object.keys(e),o=new P;return o.add(r.schedule(ve,0,{keys:n,index:0,subscriber:t,subscription:o,obj:e})),o}:function(r){for(var t=Object.keys(e),n=0;n<t.length&&!r.closed;n++){var o=t[n];e.hasOwnProperty(o)&&r.next([o,e[o]])}r.complete()})}function ve(e){var r=e.keys,t=e.index,n=e.subscriber,o=e.subscription,c=e.obj;if(!n.closed)if(t<r.length){var i=r[t];n.next([i,c[i]]),o.add(this.schedule({keys:r,index:t+1,subscriber:n,subscription:o,obj:c}))}else n.complete()}function ye(e,r,t){return[H(r,t)(new l(_(e))),H(Y(r,t))(new l(_(e)))]}function xe(e,r,t){return void 0===e&&(e=0),new l((function(n){void 0===r&&(r=e,e=0);var o=0,c=e;if(t)return t.schedule(je,0,{index:o,count:r,start:e,subscriber:n});for(;;){if(o++>=r){n.complete();break}if(n.next(c++),n.closed)break}}))}function je(e){var r=e.start,t=e.index,n=e.count,o=e.subscriber;t>=n?o.complete():(o.next(r),o.closed||(e.index=t+1,e.start=r+1,this.schedule(e)))}function ge(e,r){return new l((function(t){var n,o;try{n=e()}catch(e){return void t.error(e)}try{o=r(n)}catch(e){return void t.error(e)}var c=(o?M(o):D).subscribe(t);return function(){c.unsubscribe(),n&&n.unsubscribe()}}))}export{ee as VirtualAction,$ as VirtualTimeScheduler,Z as animationFrameScheduler,te as bindCallback,ce as bindNodeCallback,ue as fromEventPattern,fe as generate,de as iif,he as interval,re as isObservable,be as onErrorResumeNext,me as pairs,ye as partition,xe as range,ge as using};
//# sourceMappingURL=rxjs.js.map