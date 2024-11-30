function happy()
{
    alert("Yeah!!!! same to you! :)");
}

function sad()
{
    alert("Heart Broken :(")
}

function reset(ele)
{
    ele.firstElementChild.disabled = false;
}

function swap(ele)
{
    let parent = ele.parentElement;
    let first = parent.children[0];
    let last = parent.children[1];
    if(first.style.translate == '')
    {
        first.style.translate = "100% 0";
        last.style.translate = "-100% 0";
    }else{
        first.style.translate = "";
        last.style.translate = "";
    }
    last.firstElementChild.disabled = true;
}