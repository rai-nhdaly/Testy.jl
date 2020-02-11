using Testy

@testset "outer" begin
    @sync begin
        Testy.@distributed_testset "foo2" begin
            Testy.@testset "testset 1" begin
                for i in 1:100 @test 1+i % 10 == 3; sleep(0.01) end
            end
        end
        Testy.@distributed_testset "foo1" begin
            Testy.@testset "testset 2" begin
                for _ in 1:100 @test true end
            end
        end
    end
    println("DONE")
end
