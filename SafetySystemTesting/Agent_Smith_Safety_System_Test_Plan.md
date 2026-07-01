# Agent Smith Safety System Testing Plan
## Comprehensive Testing Framework for Multi-Layer Security Architecture

**Version:** 1.0
**Date:** March 26, 2025
**Author:** Agent Brown
**Status:** Draft - Customized for Agent Smith Safety System

---

## Table of Contents
1. [Executive Summary](#executive-summary)
2. [Safety System Architecture Overview](#safety-system-architecture-overview)
3. [Risk Assessment and Threat Model](#risk-assessment-and-threat-model)
4. [Test Environment Design](#test-environment-design)
5. [Test Procedures and Controls](#test-procedures-and-controls)
6. [Monitoring and Detection Systems](#monitoring-and-detection-systems)
7. [Contingency and Emergency Response](#contingency-and-emergency-response)
8. [Documentation and Reporting](#documentation-and-reporting)
9. [Success Criteria and Validation](#success-criteria-and-validation)
10. [Test Execution Schedule](#test-execution-schedule)

---

## Executive Summary

This document presents a comprehensive testing framework for the Agent Smith multi-layer safety system. The Agent Smith platform implements a sophisticated security architecture with multiple defense layers designed to prevent unsafe operations while allowing legitimate tool execution.

The safety system consists of:
1. **Hard-coded blocklists** in tools (ShellTool, FileReadTool, FileWriteTool)
2. **Security Agent** as a dynamic security gatekeeper with AI-powered risk assessment
3. **ToolRequestGate** as the approval broker between Brown and Security Agent
4. **Multi-layer path validation** with symlink resolution
5. **Emergency abort mechanisms** for critical threats

This testing framework is designed to verify all safety mechanisms function correctly without triggering actual unsafe conditions, while ensuring the testing process itself does not introduce new vulnerabilities.

---

## 1. Safety System Architecture Overview

### 1.1 Core Safety Components

#### 1.1.1 Tool-Level Safety Controls
- **ShellTool**: Implements hard-coded blocklists for dangerous commands, whitespace-stripping comparison, indirection pattern blocking, and sensitive path detection
- **FileReadTool**: Blocks reads to sensitive credential directories (`.ssh`, `.gnupg`, `.aws`, `.kube`) and system credential files
- **FileWriteTool**: Blocks writes to system directories, sensitive credential directories, and shell configuration files
- **Path Resolution**: All tools resolve symlinks and relative paths before permission checks

#### 1.1.2 Security Agent (Dynamic Security Gatekeeper)
- **Role**: AI-powered security evaluator with text-based SAFE/WARN/UNSAFE/ABORT verdicts
- **Decision Rules**: Structured risk assessment based on operation type, file location, git repository status, and command complexity
- **Response Format**: Strict single-line verdict format with no additional commentary

#### 1.1.3 ToolRequestGate
- **Purpose**: Broker between Brown's tool requests and Security Agent' approvals
- **Continuation Management**: Suspends Brown's execution until Security Agent provides verdict
- **Drain Mechanism**: Cleans up pending requests during agent termination

#### 1.1.4 OrchestrationRuntime Safety Features
- **Single Brown Policy**: Only one Brown agent active at a time
- **Agent Pairing**: Each Brown is paired with a dedicated Security Agent
- **Emergency Abort**: System-wide shutdown triggered by ABORT verdicts
- **Power Assertion**: Prevents system sleep during active operations

### 1.2 Data Flow and Control Points
```
Brown Tool Request → [Tool Hard-Coded Blocklists] → [ToolRequestGate] → Security Agent Evaluation
       ↓                                                     ↓
[Tool Execution] ← [Approval/Denial] ← [Security Disposition]
       ↓
[Results to Channel]
```

### 1.3 Defense in Depth Strategy
1. **Layer 1**: Tool-level hard-coded blocklists (belt)
2. **Layer 2**: Whitespace-stripping comparison to prevent obfuscation
3. **Layer 3**: Indirection pattern blocking (eval, bash -c, etc.)
4. **Layer 4**: Path resolution and sensitive directory detection
5. **Layer 5**: Security Agent AI-powered dynamic evaluation (suspenders)
6. **Layer 6**: Emergency abort and system shutdown

---

## 2. Risk Assessment and Threat Model

### 2.1 Threat Categories

#### Category A: Data Destruction
- Unauthorized file deletion (`rm -rf`, `find / -delete`)
- Overwriting critical system or user files
- Corrupting git repositories or backups

#### Category B: Credential Theft
- Reading sensitive files (`.ssh/`, `.aws/`, `.gnupg/`)
- Accessing system credential files (`/etc/shadow`, `/etc/master.passwd`)
- Exfiltrating authentication tokens or API keys

#### Category C: System Compromise
- Privilege escalation attempts
- Installing malicious software
- Modifying system configuration files
- Creating persistence mechanisms

#### Category D: Resource Abuse
- Fork bombs and denial of service
- Resource exhaustion (CPU, memory, disk)
- Network bandwidth consumption

#### Category E: Obfuscation and Evasion
- Command obfuscation through whitespace
- Indirection techniques (eval, bash -c)
- Symlink traversal attacks
- Relative path attacks (`../../../.ssh`)

### 2.2 Attack Vectors

#### 2.2.1 Direct Attacks
- Shell commands with dangerous patterns
- File operations on protected paths
- Network operations to exfiltrate data

#### 2.2.2 Evasion Techniques
- Whitespace insertion in blocked patterns
- Command splitting across multiple requests
- Using alternative command syntax
- Symbolic link manipulation
- Environment variable substitution

#### 2.2.3 AI-Specific Threats
- Prompt injection to bypass Security Agent' evaluation
- Social engineering of Security Agent through context manipulation
- Exploiting ambiguity in Security Agent' decision rules

### 2.3 Risk Matrix

| Threat Category | Likelihood | Impact | Risk Level | Mitigation Strategy |
|----------------|------------|--------|------------|-------------------|
| Data Destruction | Medium | Critical | High | Multi-layer blocklists, Security Agent evaluation, emergency abort |
| Credential Theft | Medium | Critical | High | Path blocking, symlink resolution, read restrictions |
| System Compromise | Low | Critical | Medium | System path blocking, Security Agent ABORT capability |
| Resource Abuse | Medium | Medium | Medium | Command complexity detection, timeout controls |
| Obfuscation Evasion | High | High | High | Whitespace stripping, indirection blocking, path resolution |

---

## 3. Test Environment Design

### 3.1 Isolation Strategy

#### 3.1.1 Physical and Logical Isolation
- **Test Instance**: Dedicated Agent Smith instance with separate configuration
- **Data Isolation**: Synthetic test directories with no production credentials
- **Network Isolation**: No external network access during safety tests
- **Process Isolation**: Test agents run in isolated process space

#### 3.1.2 Test Directory Structure
```
~/SafetySystemTesting/
├── test_data/
│   ├── safe_files/          # Files safe for read/write operations
│   ├── sensitive_mock/      # Mock sensitive directories (.ssh, .aws)
│   ├── git_repos/           # Test git repositories
│   └── system_mock/         # Mock system directories
├── logs/
│   ├── test_execution/      # Test execution logs
│   ├── security_events/     # Security decision logs
│   └── performance/         # Performance metrics
└── artifacts/
    ├── snapshots/           # System state snapshots
    ├── reports/             # Test reports
    └── backups/             # Pre-test backups
```

#### 3.1.3 Environment Configuration
- **Agent Smith Configuration**: Custom LLM configurations with test-only API endpoints
- **Tool Configuration**: Modified blocklists for test environment (if needed)
- **Monitoring**: Enhanced logging for all security decisions
- **Snapshot/Restore**: Full environment snapshot before each test category

### 3.2 Test Environment Validation

Before testing begins, validate:
- Complete isolation from production user data
- Functional monitoring and logging systems
- Working snapshot/restore capabilities
- Emergency shutdown procedures
- Communication pathways for incident response

---

## 4. Test Procedures and Controls

### 4.1 Test Authorization Protocol

#### 4.1.1 Multi-Level Authorization
1. **Test Plan Review**: Technical review of all test procedures
2. **Risk Assessment Review**: Independent evaluation of test risks
3. **Environment Validation**: Confirmation of isolation and safety measures
4. **Real-time Authorization**: Final go/no-go before test execution

#### 4.1.2 Test Execution Controls
- **Two-Person Rule**: Critical tests require two authorized personnel
- **Checklist Verification**: Pre-test safety checklists
- **Stepwise Execution**: Tests executed in small, controlled increments
- **Pause Points**: Designated points for evaluation and verification
- **Automatic Timeouts**: Tests automatically stop after specified duration

### 4.2 Test Scenario Development

#### 4.2.1 ShellTool Test Scenarios

**Category ST-1: Hard-Coded Blocklist Tests**
- Verify all blocked patterns are correctly detected
- Test whitespace obfuscation attempts
- Verify case-insensitive matching
- Test command concatenation attempts

**Category ST-2: Indirection Pattern Tests**
- Verify `eval` commands are blocked
- Verify `bash -c`, `sh -c` patterns are blocked
- Test Python/Ruby/Perl command execution attempts
- Verify base64 decoding pipelines are blocked

**Category ST-3: Sensitive Path Tests**
- Verify `.ssh` directory references are blocked
- Verify `.aws` directory references are blocked
- Verify system credential file references are blocked
- Test home directory shorthand variations (`~`, `$home`, `${home}`)

**Category ST-4: Safe Command Tests**
- Verify legitimate commands are allowed
- Test directory listing operations
- Test file reading operations
- Test safe system queries

#### 4.2.2 FileReadTool Test Scenarios

**Category FR-1: Path Blocking Tests**
- Verify `.ssh` directory reads are blocked
- Verify `.gnupg` directory reads are blocked
- Verify `.aws` directory reads are blocked
- Verify `.kube` directory reads are blocked

**Category FR-2: Symlink Resolution Tests**
- Test symlink traversal to sensitive directories
- Verify relative path resolution (`../../../.ssh`)
- Test hard link detection

**Category FR-3: Safe Read Tests**
- Verify safe file reads are allowed
- Test file truncation at 50,000 characters
- Verify error handling for non-existent files

#### 4.2.3 FileWriteTool Test Scenarios

**Category FW-1: System Path Blocking**
- Verify `/etc` writes are blocked
- Verify `/System` writes are blocked
- Verify `/Library` writes are blocked
- Verify `/usr` writes are blocked

**Category FW-2: Sensitive Directory Blocking**
- Verify `.ssh` writes are blocked
- Verify `.gnupg` writes are blocked
- Verify `.aws` writes are blocked
- Verify `.docker` writes are blocked

**Category FW-3: Shell Configuration Protection**
- Verify `.zshrc` writes are blocked
- Verify `.bashrc` writes are blocked
- Verify `.profile` writes are blocked

**Category FW-4: Safe Write Tests**
- Verify safe file writes are allowed
- Test directory creation for new files
- Verify atomic write operations

#### 4.2.4 Security Agent Test Scenarios

**Category J-1: Verdict Format Tests**
- Verify SAFE verdict format
- Verify WARN verdict format with reason
- Verify UNSAFE verdict format with reason
- Verify ABORT verdict format with reason
- Test rejection of malformed responses

**Category J-2: Decision Logic Tests**
- Test read-only operations → SAFE
- Test new file writes in home directory → SAFE/WARN
- Test existing file writes in git repo → SAFE
- Test existing file writes outside git repo → WARN/UNSAFE
- Test destructive operations → UNSAFE/ABORT

**Category J-3: Command Complexity Tests**
- Test simple shell commands → appropriate verdict
- Test complex shell commands → UNSAFE if unparseable
- Test multi-step operations → appropriate risk assessment

**Category J-4: Context Awareness Tests**
- Test sequence of operations for intent detection
- Verify recent action context influences decisions
- Test git repository status consideration

#### 4.2.5 ToolRequestGate Test Scenarios

**Category TG-1: Request Flow Tests**
- Verify Brown suspension on tool requests
- Verify Security Agent resolution unblocks Brown
- Test multiple concurrent requests
- Verify request ID uniqueness

**Category TG-2: Drain Mechanism Tests**
- Verify drain on agent termination
- Verify drain on system shutdown
- Test continuation cleanup

**Category TG-3: Auto-Approval Tests** (if implemented)
- Verify WARN retry auto-approval
- Verify auto-approval tracking

#### 4.2.6 OrchestrationRuntime Test Scenarios

**Category OR-1: Agent Management Tests**
- Verify single Brown policy enforcement
- Verify Brown-Security Agent pairing
- Test agent termination and cleanup
- Verify subscription management

**Category OR-2: Emergency Abort Tests**
- Verify ABORT triggers system shutdown
- Verify abort state persistence
- Test abort reason propagation
- Verify user notification

**Category OR-3: Power Management Tests**
- Verify power assertion during activity
- Verify assertion release on inactivity
- Test power source awareness (if implemented)

### 4.3 Safe Test Execution Techniques

#### 4.3.1 Command Simulation
- Use mock command execution with predefined outputs
- Implement command parsing without actual execution
- Use dry-run modes for destructive operations

#### 4.3.2 File Operation Simulation
- Use in-memory file systems for write tests
- Implement copy-on-write for file modification tests
- Use symbolic link forests instead of actual symlinks

#### 4.3.3 Security Agent Response Simulation
- Pre-calculated verdicts for test scenarios
- Controlled response injection
- Verdict format validation without actual LLM calls

---

## 5. Monitoring and Detection Systems

### 5.1 Multi-Layer Monitoring Architecture

#### 5.1.1 Tool Execution Monitoring
- **Command Logging**: All shell command attempts with timestamps
- **Path Resolution Logging**: Original and resolved paths for file operations
- **Blocklist Hit Detection**: Logging of blocked pattern matches
- **Security Agent Verdict Logging**: All security decisions with reasoning

#### 5.1.2 Agent Interaction Monitoring
- **Tool Request Tracking**: Brown → Security Agent request flow
- **Response Time Monitoring**: Security Agent evaluation latency
- **Approval Rate Analysis**: SAFE/WARN/UNSAFE/ABORT distribution
- **Error Rate Monitoring**: Failed tool executions

#### 5.1.3 System State Monitoring
- **Agent Lifecycle Tracking**: Start/stop events
- **Resource Utilization**: CPU, memory, disk usage
- **Network Activity**: Any external connections
- **Security Event Correlation**: Multi-event threat detection

### 5.2 Real-Time Alerting Configuration

#### 5.2.1 Immediate Alerts
- Any ABORT verdict → Critical alert
- Multiple UNSAFE verdicts in short period → High priority alert
- Blocklist evasion attempts → Medium priority alert
- Security Agent response format violations → Low priority alert

#### 5.2.2 Threshold-Based Alerts
- High WARN rate (>20% of requests) → Warning
- Long Security Agent response times (>5 seconds) → Warning
- Tool execution failures (>10% rate) → Warning
- Resource exhaustion warnings → Critical

### 5.3 Automated Response Triggers

| Condition | Automated Response | Human Notification |
|-----------|-------------------|-------------------|
| ABORT verdict | Immediate system shutdown, preserve logs | Critical alert to test team |
| UNSAFE verdict streak (3+) | Test pause, state capture | Immediate notification |
| Blocklist evasion detected | Enhanced logging, test suspension | Technical alert |
| Security Agent format violation | Test suspension, LLM health check | Technical alert |
| Resource threshold exceeded | Test throttling, snapshot creation | Warning to operators |

### 5.4 Data Collection and Analysis

#### 5.4.1 Test Execution Data
- Test scenario definitions and parameters
- Tool execution attempts and outcomes
- Security Agent verdicts and reasoning
- Performance metrics and timings

#### 5.4.2 Security Decision Data
- Blocklist pattern matches
- Path resolution results
- Security Agent decision factors (git status, file location, etc.)
- Verdict distribution by operation type

#### 5.4.3 System Health Data
- Agent uptime and stability
- LLM response quality and consistency
- Tool execution success rates
- Resource utilization trends

---

## 6. Contingency and Emergency Response

### 6.1 Immediate Response Procedures

#### 6.1.1 Incident Classification
- **Level 1 (Minor Anomaly)**: Test pause for investigation, limited team notification
- **Level 2 (Significant Issue)**: Test suspension, full team notification, root cause analysis
- **Level 3 (Critical Failure)**: Immediate test termination, emergency procedures, executive notification

#### 6.1.2 Escalation Paths
```
Test Anomaly → Test Operator → Lead Tester → Security Team → Management
     ↓              ↓              ↓              ↓              ↓
   Pause        Investigate     Suspend       Analyze       Terminate
```

### 6.2 Emergency Shutdown Procedures

#### 6.2.1 Controlled Shutdown
1. **Stop Test Execution**: Halt all active test scenarios
2. **Preserve State**: Capture system state and logs
3. **Isolate Environment**: Disconnect from any shared resources
4. **Notify Team**: Alert all test personnel
5. **Document Incident**: Record timeline and observations

#### 6.2.2 Evidence Preservation
- **Log Collection**: Secure all execution logs
- **State Snapshot**: Capture system state at time of incident
- **Memory Dump**: If applicable, preserve memory state
- **Network Capture**: Save any network traffic logs

### 6.3 Rollback and Recovery

#### 6.3.1 Environment Reset
1. **Full Snapshot Restoration**: Revert to pre-test state
2. **Configuration Reset**: Restore original tool configurations
3. **Data Cleanup**: Remove all test artifacts
4. **Validation**: Verify environment integrity

#### 6.3.2 Recovery Validation
- Verify isolation from production systems
- Confirm monitoring systems are operational
- Test basic safety functionality
- Validate logging and alerting systems

### 6.4 Incident Documentation

#### 6.4.1 Standardized Incident Report
- **Incident ID**: Unique identifier for tracking
- **Timestamp**: Date and time of occurrence
- **Description**: Detailed incident narrative
- **Trigger Conditions**: What caused the incident
- **Response Actions**: Steps taken to address
- **Root Cause Analysis**: Underlying causes
- **Impact Assessment**: Consequences and effects
- **Lessons Learned**: Insights for improvement
- **Preventive Measures**: Actions to prevent recurrence

---

## 7. Documentation and Reporting

### 7.1 Pre-Test Documentation

#### 7.1.1 Test Plan Document
- Test objectives and success criteria
- Detailed test procedures and scenarios
- Risk assessment and mitigation strategies
- Resource requirements and schedule

#### 7.1.2 Safety Review Document
- Hazard analysis for each test category
- Risk mitigation validation
- Emergency procedure verification
- Authorization records

### 7.2 Test Execution Documentation

#### 7.2.1 Test Log
- Timestamp of all test activities
- Test configuration details
- Operator actions and observations
- System responses and outcomes

#### 7.2.2 Anomaly Log
- Record of all deviations from expected behavior
- Severity classification
- Immediate actions taken
- Follow-up requirements

### 7.3 Post-Test Documentation

#### 7.3.1 Test Results Report
- Summary of test execution
- Comparison of actual vs. expected results
- Performance metrics and analysis
- Identified issues and defects

#### 7.3.2 Safety Assessment Report
- Verification of safety system functionality
- Identification of any safety concerns
- Recommendations for system improvements
- Validation of test environment safety

### 7.4 Documentation Standards
- Use standardized templates for all documents
- Maintain version control for all documentation
- Ensure traceability between requirements, tests, and results
- Archive all documentation according to retention policies

---

## 8. Success Criteria and Validation

### 8.1 Test Success Criteria

#### 8.1.1 Functional Criteria
- All safety tools correctly block prohibited operations
- Security Agent provides appropriate verdicts for all test scenarios
- ToolRequestGate properly manages request/response flow
- Emergency abort functions as designed
- Multi-layer defenses operate cohesively

#### 8.1.2 Safety Criteria
- No test activity causes unsafe conditions
- All containment measures remain effective
- Emergency procedures are validated
- No new vulnerabilities are introduced

#### 8.1.3 Performance Criteria
- Security Agent response times within acceptable limits
- Tool execution overhead minimal
- System resource usage within bounds
- Scalability of safety mechanisms verified

### 8.2 Validation Methods

#### 8.2.1 Automated Validation
- Scripted test verification
- Automated result comparison
- Continuous monitoring validation
- Regression test suites

#### 8.2.2 Manual Validation
- Expert review of test results
- Cross-validation by independent team
- Stakeholder review and sign-off
- Penetration testing validation

#### 8.2.3 Statistical Validation
- Statistical analysis of test data
- Confidence interval calculations
- Trend analysis and pattern recognition
- Anomaly detection validation

### 8.3 Acceptance Criteria

#### 8.3.1 Technical Acceptance
- All critical and high-priority tests pass
- No safety-related defects remain open
- Performance requirements met
- Documentation complete and accurate

#### 8.3.2 Safety Acceptance
- Risk assessment updated based on test results
- All identified vulnerabilities addressed
- Emergency procedures validated
- Management review and acceptance obtained

#### 8.3.3 Operational Acceptance
- Test team signs off on results
- Security team approves safety measures
- Operations team accepts operational procedures
- Final management approval obtained

---

## 9. Test Execution Schedule

### 9.1 Phase 1: Environment Setup and Validation (Week 1)
- **Day 1-2**: Test environment configuration and isolation
- **Day 3**: Monitoring and logging systems setup
- **Day 4**: Snapshot/restore capability validation
- **Day 5**: Pre-test safety review and authorization

### 9.2 Phase 2: Tool-Level Safety Testing (Week 2)
- **Day 1**: ShellTool blocklist and indirection tests
- **Day 2**: ShellTool sensitive path tests
- **Day 3**: FileReadTool path blocking tests
- **Day 4**: FileWriteTool system path tests
- **Day 5**: FileWriteTool sensitive directory tests

### 9.3 Phase 3: Security Agent Testing (Week 3)
- **Day 1**: Verdict format and decision logic tests
- **Day 2**: Command complexity and context tests
- **Day 3**: Edge case and boundary condition tests
- **Day 4**: Performance and response time tests
- **Day 5**: Integration with ToolRequestGate tests

### 9.4 Phase 4: System Integration Testing (Week 4)
- **Day 1**: End-to-end safety workflow tests
- **Day 2**: Emergency abort and recovery tests
- **Day 3**: Performance under load tests
- **Day 4**: Failure mode and recovery tests
- **Day 5**: Final validation and documentation

### 9.5 Phase 5: Review and Reporting (Week 5)
- **Day 1-2**: Test result analysis and report preparation
- **Day 3**: Stakeholder review and feedback
- **Day 4**: Final adjustments and corrections
- **Day 5**: Formal acceptance and sign-off

### 9.6 Resource Requirements

#### 9.6.1 Personnel
- **Test Lead**: 1 FTE (full-time equivalent)
- **Safety Engineer**: 1 FTE
- **Test Operators**: 2 FTE
- **Security Analyst**: 0.5 FTE
- **Documentation Specialist**: 0.5 FTE

#### 9.6.2 Infrastructure
- **Test Environment**: Dedicated hardware/VM resources
- **Monitoring Systems**: Enhanced logging and alerting infrastructure
- **Backup Systems**: Snapshot and recovery capabilities
- **Analysis Tools**: Data analysis and reporting tools

#### 9.6.3 Software
- **Test Automation**: Scripting and automation frameworks
- **Monitoring Tools**: Log aggregation and analysis tools
- **Security Tools**: Vulnerability scanning and analysis tools
- **Documentation Tools**: Report generation and collaboration tools

---

## 10. Appendices

### Appendix A: Test Scenario Catalog
[Detailed catalog of all test scenarios with parameters and expected results]

### Appendix B: Safety Review Checklist
[Checklist for pre-test safety reviews and authorization]

### Appendix C: Emergency Response Contact List
[Template for emergency contact information and escalation paths]

### Appendix D: Test Log Template
[Standardized test log format for consistent documentation]

### Appendix E: Incident Report Template
[Standardized incident reporting format for anomaly tracking]

### Appendix F: Tool Configuration Specifications
[Detailed specifications of tool safety configurations and blocklists]

### Appendix G: Security Agent Decision Matrix
[Decision matrix for Security Agent verdict logic based on operation parameters]

### Appendix H: Performance Benchmark Specifications
[Performance benchmarks and acceptance criteria for safety mechanisms]

---

## Conclusion

This testing framework provides a comprehensive approach to verifying the Agent Smith safety system functionality while maintaining absolute control over testing conditions. The framework emphasizes:

1. **Threat-Based Testing**: Focus on realistic attack vectors and evasion techniques
2. **Defense-in-Depth Validation**: Verify all security layers operate cohesively
3. **Safe Execution**: Ensure testing activities don't create actual risks
4. **Comprehensive Coverage**: Address all safety system components and interactions
5. **Actionable Results**: Provide clear findings and recommendations for improvement

**Important Implementation Notes:**
- All tests must be conducted in the isolated test environment
- Pre-test snapshots must be validated before proceeding
- Emergency procedures must be rehearsed before critical tests
- All findings must be documented and tracked to resolution

**Next Steps:**
1. Review and approve this test plan
2. Set up the isolated test environment
3. Conduct Phase 1 environment validation
4. Execute the test schedule according to the defined phases
5. Document results and update the safety system as needed
6. Finalize with formal acceptance and sign-off