// monitor.bicep
// Log Analytics Workspace + Azure Monitor Agent (VM Insights) + one
// example alert — centralized logs and metrics instead of `tail -f` on
// the VM's disk (as it was on Oracle). AZ-104 domain: Monitor and back up
// Azure resources.

@description('Deployment region')
param location string

@description('Resource name prefix')
param namePrefix string

@description('Resource ID of the monitored VM')
param vmId string

@description('Name of the monitored VM (for alert scope)')
param vmName string

@description('Common tags')
param tags object

@description('Log retention in days — 30 is the paid minimum, but plenty for a portfolio/dev project')
param retentionInDays int = 30

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${namePrefix}-law'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
  }
}

// Azure Monitor Agent on the VM — collects system metrics (CPU/RAM/disk/
// network) and (once a Data Collection Rule is configured) application logs.
resource amaExtension 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = {
  name: '${vmName}/AzureMonitorLinuxAgent'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorLinuxAgent'
    typeHandlerVersion: '1.29'
    autoUpgradeMinorVersion: true
  }
}

// Data Collection Rule: exactly what we collect from the VM (performance
// counters + syslog, including our systemd service's logs, which land in
// the system log via journald / syslog).
resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: '${namePrefix}-dcr'
  location: location
  tags: tags
  properties: {
    dataSources: {
      performanceCounters: [
        {
          name: 'perfCounters'
          streams: [
            'Microsoft-Perf'
          ]
          samplingFrequencyInSeconds: 60
          counterSpecifiers: [
            '\\Processor(_Total)\\% Processor Time'
            '\\Memory\\% Used Memory'
            '\\Memory\\Available MBytes Memory'
            '\\Logical Disk(_Total)\\% Used Space'
          ]
        }
      ]
      syslog: [
        {
          name: 'syslogSource'
          streams: [
            'Microsoft-Syslog'
          ]
          facilityNames: [
            'daemon'
            'user'
          ]
          logLevels: [
            'Info'
            'Warning'
            'Error'
            'Critical'
          ]
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: logAnalytics.id
          name: 'lawDestination'
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          'Microsoft-Perf'
        ]
        destinations: [
          'lawDestination'
        ]
      }
      {
        streams: [
          'Microsoft-Syslog'
        ]
        destinations: [
          'lawDestination'
        ]
      }
    ]
  }
}

resource dcra 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = {
  name: '${namePrefix}-dcra'
  scope: amaExtension
  properties: {
    dataCollectionRuleId: dcr.id
  }
}

// Alert: the strategy process should always be burning a bit of CPU (the
// WebSocket loop). If CPU stays near zero for a while, that's a signal the
// systemd service has died and hasn't come back up (e.g. a crash loop from
// a config error, despite Restart=always). Simpler and more reliable
// signal than watching the systemd service state directly.
resource lowCpuAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${namePrefix}-low-cpu-alert'
  location: 'global'
  tags: tags
  properties: {
    severity: 2
    enabled: true
    scopes: [
      vmId
    ]
    evaluationFrequency: 'PT15M'
    windowSize: 'PT30M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'LowCpu'
          metricName: 'Percentage CPU'
          operator: 'LessThan'
          threshold: 1
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    autoMitigate: true
  }
}

output logAnalyticsWorkspaceId string = logAnalytics.id
output logAnalyticsWorkspaceName string = logAnalytics.name
