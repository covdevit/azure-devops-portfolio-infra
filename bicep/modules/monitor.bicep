// monitor.bicep
// Log Analytics Workspace + Azure Monitor Agent (VM Insights) + jeden
// przykładowy alert — scentralizowane logi i metryki zamiast `tail -f` na
// dysku VM (jak było w Oracle). AZ-104 domena: Monitor and back up Azure
// resources.

@description('Region wdrożenia')
param location string

@description('Prefiks nazw zasobów')
param namePrefix string

@description('Resource ID monitorowanej VM')
param vmId string

@description('Nazwa monitorowanej VM (do scope alertu)')
param vmName string

@description('Tagi wspólne')
param tags object

@description('Przechowywanie logów w dniach — 30 to minimum płatne, ale wystarczające dla portfolio/dev')
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

// Azure Monitor Agent na VM — zbiera metryki systemowe (CPU/RAM/dysk/sieć)
// i (po skonfigurowaniu Data Collection Rule) logi aplikacji.
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

// Data Collection Rule: co dokładnie zbieramy z VM (metryki wydajności +
// syslog, w tym logi naszej usługi systemd, które trafiają do dziennika
// systemowego przez journald / syslog).
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

// Alert: proces strategii powinien zawsze zużywać trochę CPU (pętla
// WebSocketa); jeśli CPU spadnie blisko zera na dłużej, to sygnał, że
// usługa systemd padła i nie wstała (mimo Restart=always — np. crashloop
// z błędem konfiguracji). Prostszy i bardziej wiarygodny sygnał niż
// pilnowanie samego stanu usługi przez agenta.
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
