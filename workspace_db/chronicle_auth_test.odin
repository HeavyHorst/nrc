package workspace_db

import pr "../protocol"
import sql "../sqlite"
import "core:testing"

@(test)
test_chronicle_service_request_boundary :: proc(t: ^testing.T) {
	for operation in Operation {
		for opcode in ([]pr.Opcode{.C_Chronicle, .C_GetTasks, .C_CreateAsset, .C_Ping}) {
			request := Request {
				operation        = operation,
				opcode           = opcode,
				chronicle_access = pr.CHRONICLE_ACCESS_SERVICE,
			}
			allowed := operation == .Command && opcode == .C_Chronicle
			testing.expect_value(t, chronicle_request_allowed(request), allowed)
			if !allowed {
				// No database or handler is needed: denied jobs never reach either.
				job := Completion {
					request = request,
				}
				execute_job(nil, &job, 0, nil)
				testing.expect_value(t, job.result.status, sql.CONSTRAINT)
			}
			request.chronicle_access = pr.CHRONICLE_ACCESS_READ
			testing.expect(t, chronicle_request_allowed(request))
		}
	}
}
