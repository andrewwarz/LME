import pytest
import os
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.common.by import By
from selenium.common.exceptions import NoSuchElementException
from .lib import dashboard_test_function

class TestProcessExplorerDashboard:
    #dashboard_id = "f2cbc110-8400-11ee-a3de-f1bc0525ad6c"
    dashboard_id = "cf38381a-e9e1-4b28-914e-0819fb59e53c"

    @pytest.fixture(scope="class")
    def setup_login(self, driver, login):
        login()
        yield driver

    #@pytest.mark.skip(reason="Skipping this test")
    def test_files_created_in_downloads(self, setup_login, kibana_url, timeout):
        #This dashboard panel is not working corectly. Shows no data even when there is data. Create issue LME#294
        driver = setup_login
        dashboard_test_function(driver, kibana_url, timeout, self.dashboard_id, "Files created (in Downloads)", ".euiFlexGroup", ".euiIcon",)

    #@pytest.mark.skip(reason="This test is for reference to use in 2.0")
    def test_hosts(self, setup_login, kibana_url, timeout):
        driver = setup_login
        dashboard_test_function(driver, kibana_url, timeout, self.dashboard_id, "Hosts", ".tbvChart",".visError")
               
    #@pytest.mark.skip(reason="This test is for reference to use in 2.0")
    def test_process_spawn_event_logs_id1(self, setup_login, kibana_url, timeout):
        driver = setup_login
        dashboard_test_function(driver, kibana_url, timeout, self.dashboard_id, "Process spawn event logs (Sysmon ID 1)", ".euiDataGrid",".euiIcon")
        
    #@pytest.mark.skip(reason="This test is for reference to use in 2.0")
    def test_process_spawns_over_time(self, setup_login, kibana_url, timeout):
        driver = setup_login
        dashboard_test_function(driver, kibana_url, timeout, self.dashboard_id, "Process spawns over time", ".echChart",".euiIcon")

    #@pytest.mark.skip(reason="This test is for reference to use in 2.0")
    def test_processes_created_by_users_over_time(self, setup_login, kibana_url, timeout):
        driver = setup_login
        dashboard_test_function(driver, kibana_url, timeout, self.dashboard_id, "Processes created by users over time", ".echChart",".euiIcon")        

    #@pytest.mark.skip(reason="This test is for reference to use in 2.0")
    def test_registry_events_sysmon_12_13_14(self, setup_login, kibana_url, timeout):
        driver = setup_login
        dashboard_test_function(driver, kibana_url, timeout, self.dashboard_id, "Registry events (Sysmon 12, 13, 14)", ".euiDataGrid__focusWrap",".euiIcon")        
        
    #@pytest.mark.skip(reason="Panel shows error message on ubuntu cluster")
    def test_users(self, setup_login, kibana_url, timeout):
        driver = setup_login
        dashboard_test_function(driver, kibana_url, timeout, self.dashboard_id, "Users", ".euiDataGrid__focusWrap",".euiText")
        