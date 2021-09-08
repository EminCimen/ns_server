/*
Copyright 2020-Present Couchbase, Inc.

Use of this software is governed by the Business Source License included in
the file licenses/BSL-Couchbase.txt.  As of the Change Date specified in that
file, in accordance with the Business Source License, use of this software will
be governed by the Apache License, Version 2.0, included in the file
licenses/APL2.txt.
*/

import { MnFocusDirective } from './mn.focus.directive.js';
import { NgModule } from '../web_modules/@angular/core.js';
import { BrowserModule } from '../web_modules/@angular/platform-browser.js';
import { ReactiveFormsModule } from '../web_modules/@angular/forms.js';

export { MnSharedModule }

class MnSharedModule {
  static annotations = [
      new NgModule({
        declarations: [
          MnFocusDirective,
          // mn.components.MnAutoCompactionForm,
          // mn.components.MnPeriod,
          // mn.components.MnServicesConfig,
          // mn.components.MnSearch,
          // mn.components.MnSearchField
        ],
        exports: [
          MnFocusDirective,
          // mn.components.MnServicesConfig,
          // mn.components.MnAutoCompactionForm,
          // mn.components.MnSearch,
          // mn.components.MnSearchField
        ],
        imports: [
          ReactiveFormsModule,
          BrowserModule,
          // ngb.NgbModule,
        ]
      })
    ]
}