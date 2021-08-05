/*
Copyright 2020-Present Couchbase, Inc.

Use of this software is governed by the Business Source License included in
the file licenses/BSL-Couchbase.txt.  As of the Change Date specified in that
file, in accordance with the Business Source License, use of this software will
be governed by the Apache License, Version 2.0, included in the file
licenses/APL2.txt.
*/

import angular from "/ui/web_modules/angular.js";
import _ from "/ui/web_modules/lodash.js";

import mnPoolDefault from "/ui/app/components/mn_pool_default.js";
import mnPromiseHelper from "/ui/app/components/mn_promise_helper.js";

import mnSettingsClusterService from "./mn_settings_cluster_service.js";
import mnSettingsAutoFailoverService from "./mn_settings_auto_failover_service.js";

export default 'mnSettingsAutoFailover';

angular
  .module('mnSettingsAutoFailover', [
    mnPromiseHelper,
    mnPoolDefault,
    mnSettingsClusterService,
    mnSettingsAutoFailoverService
  ])
  .controller('mnSettingsAutoFailoverController', mnSettingsAutoFailoverController);

function mnSettingsAutoFailoverController($scope, $q, mnPromiseHelper, mnSettingsAutoFailoverService, mnPoolDefault, mnSettingsClusterService) {
  var vm = this;

  mnSettingsClusterService.registerSubmitCallback(submit);

  activate();

  function getAutoFailoverSettings() {
    var settings = {
      enabled: vm.autoFailoverSettings.enabled,
      timeout: vm.autoFailoverSettings.timeout
    };
    if (mnPoolDefault.export.compat.atLeast55 &&
        mnPoolDefault.export.isEnterprise) {
      settings.failoverOnDataDiskIssues = vm.autoFailoverSettings.failoverOnDataDiskIssues;
      settings.failoverServerGroup = vm.autoFailoverSettings.failoverServerGroup;
      settings.maxCount = vm.autoFailoverSettings.maxCount;
    }
    if (mnPoolDefault.export.compat.atLeast65 &&
        mnPoolDefault.export.isEnterprise) {
      settings.canAbortRebalance = vm.autoFailoverSettings.canAbortRebalance;
    }
    return settings;
  }

  function getReprovisionSettings() {
    return {
      enabled: vm.reprovisionSettings.enabled,
      maxNodes: vm.reprovisionSettings.max_nodes
    };
  }

  function watchOnSettings(method, dataFunc) {
    return function () {
      if (!$scope.rbac.cluster.settings.write) {
        return;
      }
      mnPromiseHelper(vm, mnSettingsAutoFailoverService[method](dataFunc(), {just_validate: 1}))
        .catchErrorsFromSuccess(function (rv) {
          vm[method + "Errors"] = rv;
          $scope.settingsClusterCtl[method + "Errors"] = rv;
        });
    }
  }

  function activate() {
    mnPromiseHelper(vm, mnSettingsAutoFailoverService.getAutoReprovisionSettings())
      .applyToScope(function (resp) {
        vm.reprovisionSettings = resp.data;

        $scope.$watch(
          'settingsAutoFailoverCtl.reprovisionSettings',
          _.debounce(watchOnSettings("postAutoReprovisionSettings", getReprovisionSettings),
                     500, {leading: true}), true);
      });

    mnPromiseHelper(vm,
                    mnSettingsAutoFailoverService.getAutoFailoverSettings())
      .applyToScope(function (resp) {
        vm.autoFailoverSettings = resp;

        $scope.$watch(
          'settingsAutoFailoverCtl.autoFailoverSettings',
          _.debounce(watchOnSettings("saveAutoFailoverSettings", getAutoFailoverSettings),
                     500, {leading: true}), true);
      });
  }

  function submit() {
    var queries = [
      mnPromiseHelper(vm, mnSettingsAutoFailoverService.saveAutoFailoverSettings(getAutoFailoverSettings()))
        .catchErrors(function (resp) {
          vm.saveAutoFailoverSettingsErrors = resp && {timeout: resp};
        })
        .getPromise(),

      mnPromiseHelper(vm, mnSettingsAutoFailoverService.postAutoReprovisionSettings(getReprovisionSettings()))
        .catchErrors(function (resp) {
          vm.postAutoReprovisionSettingsErrors = resp && {maxNodes: resp};
        })
        .getPromise()
    ];

    return $q.all(queries);
  };
}